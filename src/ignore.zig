//! Ignore files stacked as git stacks them (`dir.c`). Each file is a level:
//! its lines one `Set`, the last matching line deciding within it. Levels
//! fall in three groups, ranked lowest first: files (`core.excludesFile`,
//! then `info/exclude`), the per-directory files, and patterns from a
//! command line. Within a group the level added later wins, so a deeper
//! directory overrides a shallower one. A path under an excluded directory
//! stays excluded whatever a deeper line says; a directory excluded only by
//! its contents (`dir/*`) is not excluded, and is entered.
const std = @import("std");
const aegis = @import("aegis");
const set_mod = @import("set.zig");
const syntax = @import("syntax.zig");
const gitignore = @import("gitignore.zig");
const Pattern = @import("pattern.zig").Pattern;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Set = set_mod.Set;
const Kind = set_mod.Kind;

/// Where a level's patterns rank: a level of a higher group wins over any
/// of a lower one, whatever their order.
pub const Group = enum {
    /// `core.excludesFile` and `info/exclude`, git's `EXC_FILE`.
    file,
    /// A directory's ignore files, git's `EXC_DIRS`.
    directory,
    /// Patterns a caller names (`--exclude`, `clean -e`), git's `EXC_CMDL`.
    command_line,
};

/// The line that decided, as `git check-ignore -v` names it.
pub const Origin = struct {
    /// The level's source, as the caller named it. Borrowed from the stack.
    source: []const u8,
    /// One-based: the line in its file, or the pattern's place among those
    /// given.
    line: u32,
    /// The line as written, without its line feed. Borrowed from the stack.
    text: []const u8,
    /// A `!` line: its match re-includes.
    negated: bool,
};

/// Whether a path is excluded, and which line said so.
pub const Match = struct {
    /// `false` with an origin: a negation re-included the path. `false`
    /// with none: no line matched.
    excluded: bool,
    by: ?Origin,
};

/// Whether a file's own name may be a symbolic link.
pub const Links = enum {
    /// Read through a link: git follows `core.excludesFile` and
    /// `info/exclude`.
    follow,
    /// A link is `error.LinkRefused`: git's `PATTERN_NOFOLLOW` for a file in
    /// the working tree.
    refuse,
};

/// What a file that is there but cannot be read does.
pub const Unreadable = enum {
    /// The call fails with the error; nothing was added.
    fail,
    /// The file counts as absent and is listed in `Stack.skipped`, as git
    /// warns and goes on.
    skip,
};

/// Reading a file failed.
pub const ReadError = aegis.own.ReadFileError || Io.Dir.StatFileError || Io.Dir.OpenError || error{
    /// The file holds more than `Options.max_file` bytes; git skips one
    /// over its 100 MiB.
    FileTooLarge,
    /// The file's name is a symbolic link where `Links.refuse` was asked.
    LinkRefused,
};

/// A pattern could not join a level.
pub const AddError = Allocator.Error || error{
    /// A line longer than a pattern may be; git would match it, so the
    /// level is not added without it.
    PatternTooLong,
};

/// Adding a file's level failed.
pub const FileError = ReadError || AddError;

/// A file read as absent under `Unreadable.skip`, and why.
pub const Skipped = struct {
    /// Borrowed from the stack.
    source: []const u8,
    reason: FileError,
};

/// Where a level's patterns belong.
pub const Place = struct {
    group: Group,
    /// The directory the patterns are relative to, `/`-separated, without
    /// a trailing slash; empty at the root. Copied.
    base: []const u8 = "",
    /// What `Origin.source` says. Copied.
    source: []const u8,
};

/// How a stack reads and matches.
pub const Options = struct {
    /// `.ascii_git` for `core.ignoreCase`.
    case: syntax.Case = .sensitive,
    /// The names of a directory's ignore files, read in order: a later
    /// name's lines win over an earlier one's in the same directory.
    file_names: []const []const u8 = &.{".gitignore"},
    /// The most bytes one file may hold: git's `PATTERN_MAX_FILE_SIZE`.
    max_file: aegis.units.Bytes(u64) = .fromRaw(100 << 20),
    unreadable: Unreadable = .fail,
    /// Each level's cache capacity.
    cache: Set.Bytes = .fromRaw(1 << 16),
};

/// A position in a stack, to pop back to.
pub const Mark = enum(usize) { _ };

/// The levels of ignore files, in the order added. A stack and its caches
/// are asked from one thread at a time.
pub const Stack = struct {
    /// Private: what every level and list comes from.
    gpa: Allocator,
    /// Private: as given at `init`.
    options: Options,
    /// Private: the levels, in the order added.
    levels: std.ArrayList(Level) = .empty,
    /// Private: files read as absent under `Unreadable.skip`.
    skips: std.ArrayList(Skipped) = .empty,

    const Level = struct {
        group: Group,
        /// Owned.
        base: []u8,
        /// Owned.
        source: []u8,
        /// Owned: the file's bytes or the patterns' copies, which each
        /// origin's text borrows.
        text: []u8,
        /// Owned: one per set entry.
        origins: []Origin,
        set: Set,
        cache: Set.Cache,
        /// Where a `matchPath` pass stands.
        walking: ?Set.Ancestors = null,

        fn deinit(level: *Level, gpa: Allocator) void {
            level.cache.deinit();
            level.set.deinit();
            gpa.free(level.origins);
            gpa.free(level.text);
            gpa.free(level.source);
            gpa.free(level.base);
            level.* = undefined;
        }
    };

    /// An empty stack, which excludes nothing.
    pub fn init(gpa: Allocator, options: Options) Stack {
        return .{ .gpa = gpa, .options = options };
    }

    /// Frees every level.
    pub fn deinit(s: *Stack) void {
        s.popTo(@fromBackingInt(@intCast(0)));
        s.levels.deinit(s.gpa);
        for (s.skips.items) |entry| s.gpa.free(entry.source);
        s.skips.deinit(s.gpa);
        s.* = undefined;
    }

    /// Where the stack stands, for `popTo`.
    pub fn mark(s: *const Stack) Mark {
        return @fromBackingInt(@intCast(s.levels.items.len));
    }

    /// Drops every level added since `at`: a walk leaving a directory.
    pub fn popTo(s: *Stack, at: Mark) void {
        while (s.levels.items.len > @backingInt(at)) {
            var level = s.levels.pop().?;
            level.deinit(s.gpa);
        }
    }

    /// The files read as absent under `Unreadable.skip`, oldest first.
    pub fn skipped(s: *const Stack) []const Skipped {
        return s.skips.items;
    }

    /// A level from an ignore file's text, by its line grammar
    /// (`gitignore.parseLine`). The text is copied.
    pub fn addText(s: *Stack, text: []const u8, place: Place) AddError!void {
        try s.addLevel(try s.gpa.dupe(u8, text), .lines, place);
    }

    /// A level of patterns as given, with none of a file's line grammar
    /// (`gitignore.parsePattern`, git's `add_pattern` for `clean -e`).
    /// Copied.
    pub fn addPatterns(s: *Stack, patterns: []const []const u8, place: Place) AddError!void {
        const owned = try std.mem.concat(s.gpa, u8, patterns);
        const pieces = s.gpa.alloc([]const u8, patterns.len) catch |err| {
            s.gpa.free(owned);
            return err;
        };
        defer s.gpa.free(pieces);
        var at: usize = 0;
        for (patterns, pieces) |pattern, *piece| {
            piece.* = owned[at..][0..pattern.len];
            at += pattern.len;
        }
        try s.addLevel(owned, .{ .patterns = pieces }, place);
    }

    /// A level from the file at `path` in `dir`; nothing when it is absent.
    /// A file that cannot be read fails or is skipped as `Options.unreadable`
    /// says.
    pub fn addFile(s: *Stack, io: Io, dir: Io.Dir, path: []const u8, place: Place, links: Links) FileError!void {
        const text = s.read(io, dir, path, links) catch |err| return s.unreadable(place.source, err);
        const owned = text orelse return;
        errdefer s.gpa.free(owned);
        s.addLevel(owned, .lines, place) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PatternTooLong => return s.unreadable(place.source, error.PatternTooLong),
        };
    }

    /// A directory's ignore files (`Options.file_names`), each a level of
    /// group `directory` relative to `base`. `dir` is that directory; a
    /// file there is read only as a file, never through a link.
    pub fn addDirectory(s: *Stack, io: Io, dir: Io.Dir, base: []const u8) FileError!void {
        for (s.options.file_names) |name| {
            const source = try joined(s.gpa, base, name);
            defer s.gpa.free(source);
            try s.addFile(io, dir, name, .{ .group = .directory, .base = base, .source = source }, .refuse);
        }
    }

    fn unreadable(s: *Stack, source: []const u8, err: FileError) FileError!void {
        if (err == error.OutOfMemory or err == error.Canceled or s.options.unreadable == .fail) return err;
        const copy = try s.gpa.dupe(u8, source);
        errdefer s.gpa.free(copy);
        try s.skips.append(s.gpa, .{ .source = copy, .reason = err });
    }

    fn read(s: *Stack, io: Io, dir: Io.Dir, path: []const u8, links: Links) ReadError!?[]u8 {
        if (links == .refuse) {
            const found = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            if (found.kind == .sym_link) return error.LinkRefused;
        }
        return aegis.own.readFile(io, dir, path, s.gpa, s.options.max_file) catch |err| switch (err) {
            error.FileNotFound => null,
            error.StreamTooLong => error.FileTooLarge,
            else => |e| e,
        };
    }

    /// How a level's text divides: a file's lines, or patterns given whole,
    /// each a slice of the text.
    const Pieces = union(enum) {
        lines,
        patterns: []const []const u8,

        /// The next piece; `at` counts those given, one-based after the
        /// call.
        fn next(p: Pieces, at: *usize, lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
            defer at.* += 1;
            return switch (p) {
                .lines => lines.next(),
                .patterns => |all| if (at.* < all.len) all[at.*] else null,
            };
        }
    };

    /// A piece of a level, read: its line, the pattern no longer than a
    /// pattern may be, which bounds every count the compiler keeps of it.
    const Read = struct { line: gitignore.Line };

    /// Null for a piece that leaves no pattern.
    fn readPiece(pieces: Pieces, raw: []const u8) error{PatternTooLong}!?Read {
        const line = switch (pieces) {
            .lines => gitignore.parseLine(raw),
            .patterns => gitignore.parsePattern(raw),
        } orelse return null;
        if (line.pattern.len > Pattern.max_units) return error.PatternTooLong;
        return .{ .line = line };
    }

    /// Takes `text`, whatever it returns.
    fn addLevel(s: *Stack, text: []u8, pieces: Pieces, place: Place) AddError!void {
        var text_owned = true;
        defer if (text_owned) s.gpa.free(text);
        var origins: std.ArrayList(Origin) = .empty;
        defer origins.deinit(s.gpa);
        var builder: Set.Builder = .init(s.gpa);
        defer builder.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        var at: usize = 0;
        var number: u32 = 0;
        while (pieces.next(&at, &lines)) |raw| {
            number = aegis.int.cast(u32, at) catch return error.PatternTooLong;
            const piece = try aegis.input.Untrusted([]const u8).init(raw).parse(pieces, readPiece) orelse continue;
            const line = piece.line;
            var entry = line.entry;
            entry.options.case = s.options.case;
            _ = builder.add(line.pattern, entry) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PatternTooLong => return error.PatternTooLong,
                // git's wildmatch aborts on what sweep refuses, so the line
                // never matches there either: leaving it out decides alike.
                error.InvalidPattern => continue,
                // Every entry here takes git's slash.
                error.SeparatorMismatch => unreachable,
            };
            const written = if (pieces == .lines and raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            try origins.append(s.gpa, .{ .source = "", .line = number, .text = written, .negated = line.negated });
        }
        if (origins.items.len == 0) return;

        try s.levels.ensureUnusedCapacity(s.gpa, 1);
        const base = try s.gpa.dupe(u8, place.base);
        errdefer s.gpa.free(base);
        const source = try s.gpa.dupe(u8, place.source);
        errdefer s.gpa.free(source);
        for (origins.items) |*origin| origin.source = source;
        const owned_origins = try origins.toOwnedSlice(s.gpa);
        errdefer s.gpa.free(owned_origins);
        var compiled = builder.build() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.PatternTooLong => return error.PatternTooLong,
        };
        errdefer compiled.deinit();
        // The cache holds the set's parts, which stay where they are when
        // the set is moved into the level.
        var cache: Set.Cache = try .init(s.gpa, &compiled, .{ .capacity = s.options.cache });
        errdefer cache.deinit();
        s.levels.appendAssumeCapacity(.{
            .group = place.group,
            .base = base,
            .source = source,
            .text = text,
            .origins = owned_origins,
            .set = compiled,
            .cache = cache,
        });
        text_owned = false;
    }

    /// Whether `path` is excluded, by the path alone: its parents are a
    /// walk's to have decided. `path` is `/`-separated and relative to the
    /// stack's root.
    pub fn match(s: *Stack, path: []const u8, kind: Kind) Match {
        var best: ?Found = null;
        for (s.levels.items, 0..) |*level, i| {
            const relative = below(level.base, path) orelse continue;
            const hit = level.set.last(&level.cache, relative, kind) orelse continue;
            best = Found.better(best, .{ .level = i, .group = level.group, .entry = hit.raw() });
        }
        return s.decision(best);
    }

    /// Whether `path` is excluded, its parents considered, each level read
    /// once over the path: an excluded parent decides, and a negation below
    /// it brings nothing back.
    pub fn matchPath(s: *Stack, path: []const u8, kind: Kind) Match {
        for (s.levels.items) |*level| {
            level.walking = if (below(level.base, path)) |relative| level.set.ancestors(&level.cache, relative, kind) else null;
        }
        var at: usize = 0;
        while (true) {
            const slash = std.mem.findScalarPos(u8, path, at, '/');
            const end = slash orelse path.len;
            var best: ?Found = null;
            for (s.levels.items, 0..) |*level, i| {
                if (below(level.base, path[0..end]) == null) continue;
                const walking = &(level.walking orelse continue);
                const step = walking.next() orelse continue;
                const hit = step.last orelse continue;
                best = Found.better(best, .{ .level = i, .group = level.group, .entry = hit.raw() });
            }
            const decided = s.decision(best);
            if (decided.excluded or slash == null) return decided;
            at = slash.? + 1;
        }
    }

    const Found = struct {
        level: usize,
        group: Group,
        entry: u32,

        /// Levels are offered in the order added, so a later one of the
        /// same group or any of a higher group wins.
        fn better(best: ?Found, next: Found) Found {
            const held = best orelse return next;
            return if (@backingInt(next.group) >= @backingInt(held.group)) next else held;
        }
    };

    fn decision(s: *const Stack, found: ?Found) Match {
        const f = found orelse return .{ .excluded = false, .by = null };
        const origin = s.levels.items[f.level].origins[f.entry];
        return .{ .excluded = !origin.negated, .by = origin };
    }
};

/// `path` below the directory `base`, or null when it is not below it.
fn below(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (path.len <= base.len or path[base.len] != '/' or !std.mem.startsWith(u8, path, base)) return null;
    return path[base.len + 1 ..];
}

fn joined(gpa: Allocator, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (base.len == 0) return gpa.dupe(u8, name);
    return std.mem.concat(gpa, u8, &.{ base, "/", name });
}

/// A stack asked one path at a time, outside a walk: a watcher deciding
/// what to register, a checkout meeting an untracked file. The ignore files
/// of every directory above a path are read the first time a path below it
/// is asked about, the shallowest first, so a deeper file still overrides a
/// shallower one; those inside an excluded directory are never read, as git
/// reads none. A directory counts as read only once its files were read
/// or found absent, so a question that failed asks again.
pub const Checker = struct {
    /// The levels: the caller's first (the `file` group, any command line),
    /// then each directory's as it is read. Owned.
    stack: Stack,
    /// The tree the paths are relative to. Borrowed.
    root: Io.Dir,
    /// Private: the directories read, `""` the root. Keys owned.
    read: std.StringHashMapUnmanaged(void) = .empty,

    /// A checker over `stack`, which it now owns, for the tree at `root`.
    pub fn init(stack: Stack, root: Io.Dir) Checker {
        return .{ .stack = stack, .root = root };
    }

    /// Frees the stack and what was read into it.
    pub fn deinit(c: *Checker) void {
        var keys = c.read.keyIterator();
        while (keys.next()) |key| c.stack.gpa.free(key.*);
        c.read.deinit(c.stack.gpa);
        c.stack.deinit();
        c.* = undefined;
    }

    /// Whether `path` is excluded, its parents considered
    /// (`Stack.matchPath`). `path` is `/`-separated and relative to `root`.
    pub fn match(c: *Checker, io: Io, path: []const u8, kind: Kind) FileError!Match {
        try c.readAbove(io, path);
        return c.stack.matchPath(path, kind);
    }

    fn readAbove(c: *Checker, io: Io, path: []const u8) FileError!void {
        const gpa = c.stack.gpa;
        var end: usize = 0;
        while (true) {
            const dir = path[0..end];
            if (!c.read.contains(dir)) {
                // git reads nothing inside an excluded directory: all below
                // it is excluded by it.
                if (dir.len > 0 and c.stack.matchPath(dir, .dir).excluded) return;
                try c.read.ensureUnusedCapacity(gpa, 1);
                const key = try gpa.dupe(u8, dir);
                errdefer gpa.free(key);
                try c.readDirectory(io, key);
                c.read.putAssumeCapacity(key, {});
            }
            const slash = std.mem.findScalarPos(u8, path, if (end == 0) 0 else end + 1, '/') orelse return;
            end = slash;
        }
    }

    fn readDirectory(c: *Checker, io: Io, dir: []const u8) FileError!void {
        if (dir.len == 0) return c.stack.addDirectory(io, c.root, "");
        var opened = c.root.openDir(io, dir, .{ .follow_symlinks = false }) catch |err| switch (err) {
            // A path the tree does not hold has no files above it to read.
            error.FileNotFound, error.NotDir => return,
            else => |e| return c.stack.unreadable(dir, e),
        };
        defer opened.close(io);
        try c.stack.addDirectory(io, opened, dir);
    }
};

test {
    _ = @import("testing/ignore_test.zig");
}
