//! Optional filesystem expansion. The matcher stays pure; the walk owns
//! directory handles and path buffers and takes Io on every blocking call.
const std = @import("std");
const pattern = @import("pattern.zig");
const set_mod = @import("set.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A borrowed matcher. A set's cache must be dedicated to this walk.
pub const Matcher = union(enum) {
    pattern: *const pattern.Pattern,
    set: struct { set: *const set_mod.Set, cache: *set_mod.Set.Cache },

    fn matches(m: Matcher, path: []const u8, kind: set_mod.Kind) bool {
        return switch (m) {
            .pattern => |p| p.matches(path),
            .set => |s| s.set.any(s.cache, path, kind),
        };
    }
    fn leads(m: Matcher, dir: []const u8) bool {
        return switch (m) {
            .pattern => |p| p.leadsTo(dir),
            .set => |s| s.set.leadsTo(s.cache, dir),
        };
    }
    fn separator(m: Matcher) ?u8 {
        return switch (m) {
            .pattern => |p| p.options.syntax.separator,
            .set => |s| s.set.separator,
        };
    }
    fn base(m: Matcher) []const u8 {
        return switch (m) {
            .pattern => |p| if (!p.reading.fold) p.base() else "",
            .set => "",
        };
    }
};

/// A filesystem glob expansion. `dir`, the matcher and its set cache are
/// borrowed and must outlive the walk. Paths use `/` on every platform.
pub const Walk = struct {
    /// Private: allocations and directory stack owned by this walk.
    gpa: Allocator,
    frames: std.ArrayList(Frame) = .empty,
    path: std.ArrayList(u8) = .empty,
    matcher: Matcher,
    options: Options,
    sorted: ?Paths = null,
    index: usize = 0,

    /// Expansion policy, independent of the pattern dialect.
    pub const Options = struct {
        /// Follow directory symlinks; cycles through an ancestor are skipped.
        follow_symlinks: bool = false,
        /// Include hidden entries when the pattern permits them. False
        /// excludes hidden entries even if the pattern names them explicitly.
        hidden: bool = true,
        /// Return files alone rather than both files and directories.
        files_only: bool = false,
        /// Lexical ordering collects matches before returning the first one.
        order: enum { filesystem, lexical } = .filesystem,
    };
    /// A path relative to `dir`, borrowed until the next call or deinit.
    pub const Entry = struct { path: []const u8, kind: set_mod.Kind };
    /// Opening, reading or allocating the expansion failed.
    pub const OpenError = Allocator.Error || Io.Dir.OpenError || Io.Dir.RealPathError || error{InvalidSeparator};
    /// Traversal failed; the walk remains valid and still needs deinit.
    pub const NextError = OpenError || Io.Dir.Iterator.Error || Io.Dir.StatFileError;

    const Frame = struct {
        dir: Io.Dir,
        iterator: Io.Dir.Iterator,
        prefix: usize,
        canonical: ?[]u8,
    };

    /// Opens a walk, starting at a sensitive pattern's invariant base.
    /// Only `/` path separators are valid for filesystem expansion.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, matcher: Matcher, options: Options) OpenError!Walk {
        if (matcher.separator() != '/') return error.InvalidSeparator;
        var walk: Walk = .{ .gpa = gpa, .matcher = matcher, .options = options };
        errdefer walk.deinit(io);
        if (!matcher.leads("")) return walk;
        const root = try dir.openDir(io, ".", .{ .iterate = true });
        _ = walk.push(io, root, 0) catch |err| {
            root.close(io);
            return err;
        };
        // Open each base component separately, so no-follow also applies
        // to symlinks in the middle of the base.
        var components = std.mem.splitScalar(u8, matcher.base(), '/');
        while (components.next()) |component| {
            if (component.len == 0) continue;
            if (!options.hidden and component[0] == '.') {
                walk.clear(io);
                return walk;
            }
            const parent = walk.frames.items[walk.frames.items.len - 1].dir;
            const child = parent.openDir(io, component, .{ .iterate = true, .follow_symlinks = options.follow_symlinks }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir, error.SymLinkLoop => {
                    walk.clear(io);
                    return walk;
                },
                else => return err,
            };
            errdefer child.close(io);
            if (walk.path.items.len > 0) try walk.path.append(gpa, '/');
            try walk.path.appendSlice(gpa, component);
            if (!try walk.push(io, child, walk.path.items.len)) {
                walk.clear(io);
                return walk;
            }
            // The base is invariant: ancestors need not be enumerated.
            const current = walk.frames.pop().?;
            walk.clear(io);
            walk.frames.appendAssumeCapacity(current);
        }
        return walk;
    }

    /// Releases every owned directory and buffer. The caller's root stays open.
    pub fn deinit(w: *Walk, io: Io) void {
        w.clear(io);
        w.frames.deinit(w.gpa);
        w.path.deinit(w.gpa);
        if (w.sorted) |*paths| paths.deinit();
        w.* = undefined;
    }

    /// Returns the next match, pruning directories that cannot lead to one.
    pub fn next(w: *Walk, io: Io) NextError!?Entry {
        if (w.options.order == .filesystem) return w.nextRaw(io);
        if (w.sorted == null) {
            var paths: Paths = .{ .gpa = w.gpa };
            errdefer paths.deinit();
            while (try w.nextRaw(io)) |entry| try paths.add(entry);
            paths.sort();
            w.sorted = paths;
        }
        const entries = w.sorted.?.entries.items;
        if (w.index == entries.len) return null;
        const entry = entries[w.index];
        w.index += 1;
        return entry;
    }

    fn nextRaw(w: *Walk, io: Io) NextError!?Entry {
        while (w.frames.items.len > 0) {
            const frame = &w.frames.items[w.frames.items.len - 1];
            const item = (try frame.iterator.next(io)) orelse {
                w.pop(io);
                continue;
            };
            if (!w.options.hidden and item.name[0] == '.') continue;
            w.path.shrinkRetainingCapacity(frame.prefix);
            if (frame.prefix > 0) try w.path.append(w.gpa, '/');
            try w.path.appendSlice(w.gpa, item.name);
            var kind = item.kind;
            if (kind == .unknown or (kind == .sym_link and w.options.follow_symlinks)) {
                const stat = frame.dir.statFile(io, item.name, .{ .follow_symlinks = w.options.follow_symlinks }) catch |err| switch (err) {
                    error.FileNotFound, error.SymLinkLoop => continue,
                    else => return err,
                };
                kind = stat.kind;
            }
            const directory = kind == .directory;
            const entry: Entry = .{ .path = w.path.items, .kind = if (directory) .dir else .file };
            const matched = (!directory or !w.options.files_only) and w.matcher.matches(entry.path, entry.kind);
            if (directory and w.matcher.leads(entry.path)) {
                const child = frame.dir.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = w.options.follow_symlinks }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.SymLinkLoop => if (matched) return entry else continue,
                    else => return err,
                };
                _ = w.push(io, child, w.path.items.len) catch |err| {
                    child.close(io);
                    return err;
                };
            }
            if (matched) return entry;
        }
        return null;
    }

    fn push(w: *Walk, io: Io, dir: Io.Dir, prefix: usize) OpenError!bool {
        var canonical: ?[]u8 = null;
        errdefer if (canonical) |name| w.gpa.free(name);
        if (w.options.follow_symlinks) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const len = try dir.realPath(io, &buffer);
            for (w.frames.items) |ancestor| if (std.mem.eql(u8, ancestor.canonical.?, buffer[0..len])) {
                dir.close(io);
                return false;
            };
            canonical = try w.gpa.dupe(u8, buffer[0..len]);
        }
        try w.frames.append(w.gpa, .{ .dir = dir, .iterator = dir.iterate(), .prefix = prefix, .canonical = canonical });
        return true;
    }
    fn pop(w: *Walk, io: Io) void {
        const frame = w.frames.pop().?;
        frame.dir.close(io);
        if (frame.canonical) |name| w.gpa.free(name);
    }
    fn clear(w: *Walk, io: Io) void {
        while (w.frames.items.len > 0) w.pop(io);
    }
};

/// Owned expansion results. Paths stay valid until deinit.
pub const Paths = struct {
    /// Private: each entry's path is an allocation from gpa.
    gpa: Allocator,
    entries: std.ArrayList(Walk.Entry) = .empty,
    /// Releases all paths and the list.
    pub fn deinit(p: *Paths) void {
        for (p.entries.items) |entry| p.gpa.free(entry.path);
        p.entries.deinit(p.gpa);
        p.* = undefined;
    }
    /// All matches, borrowed until deinit.
    pub fn items(p: *const Paths) []const Walk.Entry {
        return p.entries.items;
    }
    fn add(p: *Paths, entry: Walk.Entry) Allocator.Error!void {
        const path = try p.gpa.dupe(u8, entry.path);
        errdefer p.gpa.free(path);
        try p.entries.append(p.gpa, .{ .path = path, .kind = entry.kind });
    }
    fn sort(p: *Paths) void {
        std.mem.sortUnstable(Walk.Entry, p.entries.items, {}, struct {
            fn less(_: void, a: Walk.Entry, b: Walk.Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
    }
};

/// Expands a Pattern or Set against a directory, with caller-owned results.
pub fn expand(gpa: Allocator, io: Io, dir: Io.Dir, matcher: Matcher, options: Walk.Options) Walk.NextError!Paths {
    var unsorted = options;
    unsorted.order = .filesystem;
    var walk = try Walk.open(gpa, io, dir, matcher, unsorted);
    defer walk.deinit(io);
    var paths: Paths = .{ .gpa = gpa };
    errdefer paths.deinit();
    while (try walk.next(io)) |entry| try paths.add(entry);
    if (options.order == .lexical) paths.sort();
    return paths;
}
