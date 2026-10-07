//! Memory: every allocation failure is survived without a leak, and no
//! query allocates.
const std = @import("std");
const sweep = @import("../sweep.zig");

const Set = sweep.Set;
const Pattern = sweep.Pattern;

const patterns = [_]struct { []const u8, sweep.Options }{
    .{ "src/**/test_*.zig", .{} },
    .{ "*.{c,h}", .{ .syntax = .glob, .anywhere = true } },
    .{ "build/**", .{} },
    .{ "[[:alpha:]é-ü]*", .{ .syntax = .posix } },
    .{ "a{b,{c,d}*}e", .{ .syntax = .glob, .case = .ascii } },
};

fn compileAll(gpa: std.mem.Allocator) !void {
    for (patterns) |case| {
        var p: Pattern = try .compile(gpa, case[0], case[1]);
        defer p.deinit();
        _ = p.matches("src/a/test_b.zig");
    }
}

test "Pattern.compile survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileAll, .{});
}

fn buildSet(gpa: std.mem.Allocator) !void {
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    for (patterns) |case| _ = try builder.add(case[0], .{ .options = case[1] });
    _ = try builder.add("node_modules", .{ .options = .{ .anywhere = true }, .dir_only = true });
    _ = try builder.add("a/b/c", .{});
    var set = try builder.build();
    defer set.deinit();
    var cache: Set.Cache = try .init(gpa, &set, .{ .capacity = 1 << 16 });
    defer cache.deinit();
    _ = set.last(&cache, "x/node_modules", .dir);
}

test "Set building survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildSet, .{});
}

const subjects = [_][]const u8{ "src/a/test_b.zig", "lib/x.h", "build/a/b", "été", "abde", "aCe", "x/node_modules/y", "a/b/c", "" };

test "Pattern queries allocate nothing" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    for (patterns) |case| {
        var p: Pattern = try .compile(gpa, case[0], case[1]);
        defer p.deinit();
        const before = failing.allocations;
        for (subjects) |subject| {
            _ = p.matches(subject);
            _ = p.matchesWith(subject, .nfa);
            _ = p.ancestor(subject);
            _ = p.leadsTo(subject);
        }
        try std.testing.expectEqual(before, failing.allocations);
    }
}

test "Set queries allocate nothing after Cache.init" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    for (patterns) |case| _ = try builder.add(case[0], .{ .options = case[1] });
    _ = try builder.add("node_modules", .{ .options = .{ .anywhere = true }, .dir_only = true });
    var set = try builder.build();
    defer set.deinit();
    // The smallest cache, so queries clear it and fall back to the NFA too.
    var cache: Set.Cache = try .init(gpa, &set, .{ .capacity = 0 });
    defer cache.deinit();
    var out: std.ArrayList(u32) = try .initCapacity(gpa, set.len() * subjects.len);
    defer out.deinit(gpa);
    const before = failing.allocations;
    for (0..50) |_| for (subjects) |subject| {
        _ = set.any(&cache, subject, .file);
        _ = set.first(&cache, subject, .dir);
        _ = set.last(&cache, subject, .file);
        _ = set.leadsTo(&cache, subject);
        out.clearRetainingCapacity();
        try set.all(gpa, &cache, subject, .dir, &out);
        var it = set.ancestors(&cache, subject, .file);
        while (it.next()) |_| {}
    };
    try std.testing.expectEqual(before, failing.allocations);
}
