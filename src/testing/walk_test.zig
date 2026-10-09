const std = @import("std");
const sweep = @import("sweep.glob");
const walking = @import("../walk.zig");
const shakedown = @import("shakedown");
const gpa = std.testing.allocator;

fn tree(io: std.Io, dir: std.Io.Dir) !void {
    for ([_][]const u8{ "src/lib", "src/.hidden", "other/deep" }) |path| try dir.createDirPath(io, path);
    for ([_][]const u8{ "src/a.c", "src/lib/b.h", "src/.hidden/c.c", "src/a.txt", "other/deep/d.c", "src/lib.c" }) |path| try dir.writeFile(io, .{ .sub_path = path, .data = "" });
}

fn pathsEqual(paths: *const walking.Paths, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, paths.items().len);
    for (paths.items(), want) |entry, name| try std.testing.expectEqualStrings(name, entry.path);
}

test "complete Walk expansion starts at base, prunes, and sorts globally" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(io, tmp.dir);
    var p: sweep.Pattern = try .compile(gpa, "src/**/*.{c,h}", .{ .syntax = .glob });
    defer p.deinit();
    var paths = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &p }, .{ .hidden = false, .files_only = true, .order = .lexical });
    defer paths.deinit();
    try pathsEqual(&paths, &.{ "src/a.c", "src/lib.c", "src/lib/b.h" });
    var b: sweep.Set.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.add("src/**/*.h", .{});
    _ = try b.add("other/**/*.c", .{});
    var set = try b.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
    defer cache.deinit();
    var many = try walking.expand(gpa, io, tmp.dir, .{ .set = .{ .set = &set, .cache = &cache } }, .{ .order = .lexical });
    defer many.deinit();
    try pathsEqual(&many, &.{ "other/deep/d.c", "src/lib/b.h" });
}

fn failedExpansion(gpa_: std.mem.Allocator, dir: std.Io.Dir, p: *const sweep.Pattern) !void {
    var paths = try walking.expand(gpa_, std.testing.io, dir, .{ .pattern = p }, .{ .order = .lexical });
    defer paths.deinit();
}

test "complete Walk survives all allocation failures and Io cancellation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(io, tmp.dir);
    var p: sweep.Pattern = try .compile(gpa, "**/*.c", .{});
    defer p.deinit();
    var allocator: shakedown.alloc.NoResize = .init(gpa);
    try std.testing.checkAllAllocationFailures(allocator.allocator(), failedExpansion, .{ tmp.dir, &p });
    const fault = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirOpenDir, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer fault.deinit();
    try std.testing.expectError(error.Canceled, walking.Walk.open(gpa, fault.io(), tmp.dir, .{ .pattern = &p }, .{}));
    try std.testing.expectEqual(@as(u64, 1), fault.count(.dirOpenDir));
}

test "complete Walk symlink policy and ancestor cycles" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(io, tmp.dir);
    tmp.dir.symLink(io, "src", "alias", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink(io, "../..", "src/lib/loop", .{ .is_directory = true });
    var p: sweep.Pattern = try .compile(gpa, "**/*.c", .{});
    defer p.deinit();
    var followed = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &p }, .{ .follow_symlinks = true, .files_only = true, .order = .lexical });
    defer followed.deinit();
    try pathsEqual(&followed, &.{ "alias/.hidden/c.c", "alias/a.c", "alias/lib.c", "other/deep/d.c", "src/.hidden/c.c", "src/a.c", "src/lib.c" });
    var base: sweep.Pattern = try .compile(gpa, "alias/**/*.c", .{});
    defer base.deinit();
    var ignored = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &base }, .{});
    defer ignored.deinit();
    try std.testing.expectEqual(@as(usize, 0), ignored.items().len);
}

test "complete Walk propagates directory read faults and closes its handles" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(io, tmp.dir);
    var p: sweep.Pattern = try .compile(gpa, "**/*.c", .{});
    defer p.deinit();
    const fault = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirRead, .n = 1 } }, .fault = .{ .fail = error.SystemResources } }} });
    defer fault.deinit();
    var walk = try walking.Walk.open(gpa, fault.io(), tmp.dir, .{ .pattern = &p }, .{});
    defer walk.deinit(fault.io());
    try std.testing.expectError(error.SystemResources, walk.next(fault.io()));
    try std.testing.expectEqual(@as(u64, 1), fault.count(.dirRead));
}

test "complete Walk skips reported link loops and propagates unexpected Io errors" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "" });
    try tmp.dir.createDirPath(io, "inside");
    const root = try tmp.dir.openDir(io, "inside", .{ .iterate = true });
    defer root.close(io);
    root.symLink(io, "../plain.txt", "link.c", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    var p = try sweep.Pattern.compile(gpa, "**/*.c", .{});
    defer p.deinit();
    // A backend can report an unresolved link as either a loop or an
    // unexpected OS status. Test the Io boundary without assuming its mapping.
    for ([_]anyerror{ error.SymLinkLoop, error.Unexpected }) |failure| {
        const fault = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirStatFile, .n = 1 } }, .fault = .{ .fail = failure } }} });
        defer fault.deinit();
        {
            var walk = try walking.Walk.open(gpa, fault.io(), root, .{ .pattern = &p }, .{ .follow_symlinks = true });
            defer walk.deinit(fault.io());
            if (failure == error.SymLinkLoop) {
                try std.testing.expectEqual(@as(?walking.Walk.Entry, null), try walk.next(fault.io()));
            } else try std.testing.expectError(error.Unexpected, walk.next(fault.io()));
        }
        try std.testing.expectEqual(@as(u64, 1), fault.count(.dirStatFile));
        try std.testing.expectEqual(fault.count(.dirOpenDir), fault.count(.dirClose));
    }
}
