const std = @import("std");
const sweep = @import("../sweep.zig");
const pattern_mod = @import("../pattern.zig");
const unicode = @import("../unicode.zig");
const shake = @import("shakedown");

fn engines(gpa: std.mem.Allocator, text: []const u8, subject: []const u8, options: sweep.Options, expected: bool) !void {
    const one = try sweep.match(text, subject, options);
    try std.testing.expectEqual(expected, one);
    var p: sweep.Pattern = try .compile(gpa, text, options);
    defer p.deinit();
    try std.testing.expectEqual(one, p.matches(subject));
    try std.testing.expectEqual(one, pattern_mod.matchesBy(&p, subject, .nfa));
    var captures = try p.captureCache(gpa);
    defer captures.deinit();
    const out = try gpa.alloc(?sweep.Pattern.Capture, captures.count());
    defer gpa.free(out);
    try std.testing.expectEqual(one, try p.captures(&captures, subject, out));
    var b: sweep.Set.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.add(text, .{ .options = options });
    var set = try b.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(gpa, &set, .{ .capacity = 0 });
    defer cache.deinit();
    try std.testing.expectEqual(one, set.any(&cache, subject, .file));
}

fn decimal(_: void, c: *shake.Case) !void {
    const lo = shake.gen.intRange(c.source, i32, -500, 500);
    const hi = lo + shake.gen.intRange(c.source, i32, 0, 500);
    const number = shake.gen.intRange(c.source, i32, -1000, 1000);
    const text = try c.gpa.print("x{{{d}..{d}}}.c", .{ lo, hi });
    const subject = try c.gpa.print("x{d}.c", .{number});
    try engines(c.gpa, text, subject, .{ .syntax = .editorconfig }, lo <= number and number <= hi);
}

test "complete decimal intervals agree with integer arithmetic" {
    try shake.check(std.testing.allocator, {}, decimal, .{ .cases = 1000 });
}

fn repeated(subject: []const u8, alternatives: []const []const u8, minimum: usize, maximum: usize, count: usize) bool {
    if (subject.len == 0 and count >= minimum and count <= maximum) return true;
    if (count >= maximum) return false;
    for (alternatives) |alt| {
        // An empty repetition changes no language after satisfying +.
        if (alt.len == 0) {
            if (subject.len == 0 and count + 1 >= minimum) return true;
        } else if (std.mem.startsWith(u8, subject, alt) and repeated(subject[alt.len..], alternatives, minimum, maximum, count + 1)) return true;
    }
    return false;
}

fn letter(source: *shake.Source) u8 {
    return shake.gen.oneOf(source, u8, "abc/");
}

fn extglob(_: void, c: *shake.Case) !void {
    const op = shake.gen.oneOf(c.source, u8, "?*+@");
    const alternatives = [_][]const []const u8{ &.{ "a", "b" }, &.{ "a", "ab" }, &.{ "", "a" }, &.{ "a", "", "b" } };
    const inner = [_][]const u8{ "a|b", "a|ab", "|a", "a|?(b)" };
    const choice = shake.gen.intRange(c.source, usize, 0, 3);
    const text = try c.gpa.print("{c}({s})c", .{ op, inner[choice] });
    const subject = try shake.gen.slice(c.source, u8, letter, c.gpa, .{ .min_len = 0, .max_len = 8 });
    const minimum: usize = if (op == '+' or op == '@') 1 else 0;
    const maximum: usize = if (op == '@' or op == '?') 1 else subject.len + 1;
    const expected = subject.len > 0 and subject[subject.len - 1] == 'c' and repeated(subject[0 .. subject.len - 1], alternatives[choice], minimum, maximum, 0);
    try engines(c.gpa, text, subject, .{ .syntax = .{ .extglob = true } }, expected);
}

test "complete regular extglobs agree with short expansion oracle" {
    try shake.check(std.testing.allocator, {}, extglob, .{ .cases = 2000 });
}

test "complete Unicode table agrees with raw default simple folding records" {
    var lines = std.mem.splitScalar(u8, @embedFile("CaseFolding.txt"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const from = try std.fmt.parseInt(u21, std.mem.trim(u8, fields.next().?, " "), 16);
        const status = std.mem.trim(u8, fields.next().?, " ");
        if (!std.mem.eql(u8, status, "C") and !std.mem.eql(u8, status, "S")) continue;
        const to = try std.fmt.parseInt(u21, std.mem.trim(u8, fields.next().?, " "), 16);
        try std.testing.expectEqual(to, unicode.fold(from));
        try std.testing.expectEqual(to, unicode.fold(to));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1533), count);
    try std.testing.expectEqual(@as(u21, 0x130), unicode.fold(0x130));
    try std.testing.expectEqual(@as(u21, 0x1100ff), unicode.fold(0x1100ff));
}

fn resources(gpa: std.mem.Allocator) !void {
    var p: sweep.Pattern = try .compile(gpa, "*(a|b)?[Σ]", .{ .syntax = .{ .extglob = true, .unit = .utf8 }, .case = .unicode });
    defer p.deinit();
    var cache = try p.captureCache(gpa);
    defer cache.deinit();
}

test "complete capture cache survives all allocation failures and queries allocate nothing" {
    var backing: shake.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(backing.allocator(), resources, .{});
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var p: sweep.Pattern = try .compile(failing.allocator(), "*(a|b)?[Σ]", .{ .syntax = .{ .extglob = true, .unit = .utf8 }, .case = .unicode });
    defer p.deinit();
    var cache = try p.captureCache(failing.allocator());
    defer cache.deinit();
    var out: [16]?sweep.Pattern.Capture = undefined;
    const before = failing.allocations;
    try std.testing.expect(try p.captures(&cache, "ababXς", &out));
    try std.testing.expect(!try p.captures(&cache, "abab", &out));
    try std.testing.expectEqual(before, failing.allocations);
}

test "complete syntax agrees with independent generated vectors" {
    var lines = std.mem.splitScalar(u8, @embedFile("syntax.tsv"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const mode = fields.next().?;
        const text = fields.next().?;
        const subject = fields.next().?;
        const want = std.mem.eql(u8, fields.next().?, "1");
        const options: sweep.Options = if (std.mem.eql(u8, mode, "ec")) .{ .syntax = .editorconfig } else .{ .syntax = .{ .extglob = true } };
        try engines(std.testing.allocator, text, subject, options, want);
    }
}

test "complete captures agree with independent generated vectors" {
    var lines = std.mem.splitScalar(u8, @embedFile("captures.tsv"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const text = fields.next().?;
        const subject = fields.next().?;
        const expected = fields.next().?;
        var p = try sweep.Pattern.compile(std.testing.allocator, text, .{ .syntax = .glob });
        defer p.deinit();
        var cache = try p.captureCache(std.testing.allocator);
        defer cache.deinit();
        var out: [16]?sweep.Pattern.Capture = undefined;
        const matched = try p.captures(&cache, subject, &out);
        if (std.mem.eql(u8, expected, "<false>")) {
            try std.testing.expect(!matched);
            continue;
        }
        try std.testing.expect(matched);
        var want = std.mem.splitScalar(u8, expected, '|');
        for (out[0..cache.count()]) |capture| {
            const value = want.next().?;
            if (capture) |c| try std.testing.expectEqualStrings(value, subject[c.start..c.end]) else try std.testing.expectEqualStrings("<null>", value);
        }
        try std.testing.expect(want.next() == null);
    }
}
