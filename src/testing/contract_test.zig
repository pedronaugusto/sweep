//! The README's promises held over generated patterns: a walk returns
//! exactly the paths of the tree that match, each once; every match starts
//! with its pattern's literal prefix and its base; captures say what
//! `matches` says, change nothing on a nonmatch and lie in the subject.
const std = @import("std");
const shakedown = @import("shakedown");
const sweep = @import("../glob.zig");
const walking = @import("../walk.zig");

const testing = std.testing;
const gen = shakedown.gen;
const options: sweep.Options = .{ .syntax = .glob };

/// A component of a pattern and the texts that match it.
const Piece = struct { pattern: []const u8, instances: []const []const u8 };
const pieces = [_]Piece{
    .{ .pattern = "*", .instances = &.{ "a", "ab", "c.c" } },
    .{ .pattern = "a", .instances = &.{"a"} },
    .{ .pattern = "a*", .instances = &.{ "a", "ab" } },
    .{ .pattern = "?", .instances = &.{ "a", "b" } },
    .{ .pattern = "**", .instances = &.{ "a", "a/b", "b/ab" } },
    .{ .pattern = "{a,b}", .instances = &.{ "a", "b" } },
    .{ .pattern = "[ab]*", .instances = &.{ "a", "ab", "b" } },
    .{ .pattern = "*.c", .instances = &.{ "c.c", "ab.c" } },
    .{ .pattern = "ab", .instances = &.{"ab"} },
};
const names = [_][]const u8{ "a", "b", "ab", "c.c", "ab.c" };

/// A pattern of one to three pieces, and a subject: an instance of it, or
/// now and then one with a component changed.
const Drawn = struct { pattern: []const u8, subject: []const u8 };

fn draw(s: *shakedown.Source, pattern: []u8, subject: []u8) Drawn {
    var p: usize = 0;
    var q: usize = 0;
    const n = gen.intRange(s, usize, 1, 3);
    for (0..n) |i| {
        const piece = pieces[gen.intRange(s, usize, 0, pieces.len - 1)];
        if (i != 0) {
            pattern[p] = '/';
            subject[q] = '/';
            p += 1;
            q += 1;
        }
        @memcpy(pattern[p..][0..piece.pattern.len], piece.pattern);
        p += piece.pattern.len;
        const text = if (gen.intRange(s, u8, 0, 4) == 0) names[gen.intRange(s, usize, 0, names.len - 1)] else piece.instances[gen.intRange(s, usize, 0, piece.instances.len - 1)];
        @memcpy(subject[q..][0..text.len], text);
        q += text.len;
    }
    return .{ .pattern = pattern[0..p], .subject = subject[0..q] };
}

test "every match starts with its pattern's literal prefix and its base" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var pattern: [64]u8 = undefined;
            var subject: [64]u8 = undefined;
            const d = draw(case.source, &pattern, &subject);
            var p: sweep.Pattern = try .compile(testing.allocator, d.pattern, options);
            defer p.deinit();
            if (!p.matches(d.subject)) return;
            const prefix = d.pattern[0..sweep.literalPrefix(d.pattern, options.syntax)];
            try testing.expect(std.mem.startsWith(u8, d.subject, prefix));
            const base = p.base();
            if (base.len != 0) try testing.expect(std.mem.eql(u8, d.subject, base) or
                (std.mem.startsWith(u8, d.subject, base) and d.subject.len > base.len and d.subject[base.len] == '/'));
        }
    }.one, .{ .cases = 2000 });
}

test "captures say what matches says, change nothing on a nonmatch, and lie in the subject" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var pattern: [64]u8 = undefined;
            var subject: [64]u8 = undefined;
            const d = draw(case.source, &pattern, &subject);
            var p: sweep.Pattern = try .compile(testing.allocator, d.pattern, options);
            defer p.deinit();
            var cache = try p.captureCache(testing.allocator);
            defer cache.deinit();
            var out: [32]?sweep.Pattern.Capture = undefined;
            const slots = out[0..cache.count()];
            const untouched: sweep.Pattern.Capture = .{ .start = 999, .end = 999 };
            @memset(slots, untouched);
            const got = try p.captures(&cache, d.subject, slots);
            try testing.expectEqual(p.matches(d.subject), got);
            for (slots) |slot| {
                if (!got) {
                    try testing.expectEqual(untouched, slot.?);
                    continue;
                }
                const c = slot orelse continue;
                try testing.expect(c.start <= c.end and c.end <= d.subject.len);
            }
        }
    }.one, .{ .cases = 2000 });
}

/// Every path under `dir`, files and directories, relative to it.
fn everything(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, into: *std.ArrayList([]u8)) !void {
    var pending: std.ArrayList([]u8) = .empty;
    defer {
        for (pending.items) |p| gpa.free(p);
        pending.deinit(gpa);
    }
    try pending.append(gpa, try gpa.dupe(u8, ""));
    while (pending.pop()) |prefix| {
        defer gpa.free(prefix);
        var sub = if (prefix.len == 0) try dir.openDir(io, ".", .{ .iterate = true }) else try dir.openDir(io, prefix, .{ .iterate = true });
        defer sub.close(io);
        var it = sub.iterate();
        while (try it.next(io)) |entry| {
            const path = if (prefix.len == 0) try gpa.dupe(u8, entry.name) else try std.fs.path.join(gpa, &.{ prefix, entry.name });
            errdefer gpa.free(path);
            if (entry.kind == .directory) try pending.append(gpa, try gpa.dupe(u8, path));
            try into.append(gpa, path);
        }
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "a walk returns exactly the paths of the tree that match, each once" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gpa = testing.allocator;
            const io = testing.io;
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            // A tree of up to eight files, each up to three directories deep.
            for (0..gen.intRange(case.source, usize, 1, 8)) |_| {
                var path: [64]u8 = undefined;
                var len: usize = 0;
                const depth = gen.intRange(case.source, usize, 0, 2);
                for (0..depth + 1) |i| {
                    if (i != 0) {
                        path[len] = '/';
                        len += 1;
                    }
                    const name = names[gen.intRange(case.source, usize, 0, names.len - 1)];
                    @memcpy(path[len..][0..name.len], name);
                    len += name.len;
                }
                if (std.fs.path.dirname(path[0..len])) |parent| tmp.dir.createDirPath(io, parent) catch continue;
                tmp.dir.writeFile(io, .{ .sub_path = path[0..len], .data = "" }) catch continue;
            }
            var pattern: [64]u8 = undefined;
            var subject: [64]u8 = undefined;
            const d = draw(case.source, &pattern, &subject);
            var p: sweep.Pattern = try .compile(gpa, d.pattern, options);
            defer p.deinit();

            var all: std.ArrayList([]u8) = .empty;
            defer {
                for (all.items) |path| gpa.free(path);
                all.deinit(gpa);
            }
            try everything(gpa, io, tmp.dir, &all);
            var want: std.ArrayList([]const u8) = .empty;
            defer want.deinit(gpa);
            for (all.items) |path| if (p.matches(path)) try want.append(gpa, path);
            std.mem.sort([]const u8, want.items, {}, lessThan);

            var paths = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &p }, .{ .order = .lexical });
            defer paths.deinit();
            errdefer std.debug.print("pattern {s}: walked {d}, matching {d}\n", .{ d.pattern, paths.items().len, want.items.len });
            try testing.expectEqual(want.items.len, paths.items().len);
            for (want.items, paths.items()) |w, got| try testing.expectEqualStrings(w, got.path);
        }
    }.one, .{ .cases = 200 });
}
