const std = @import("std");
const shakedown = @import("shakedown");
const sweep = @import("../sweep.zig");
const normal = @import("../normal.zig");
const t = std.testing;
const options: sweep.Options = .{ .syntax = .glob, .normalization = .nfc };

test "NFC parsed syntax and composed wildcard boundaries" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "[é]", "e\u{301}", true },
        .{ "[e\u{301}]", "é", true },
        .{ "[é]", "e", false },
        .{ "?", "e\u{301}", true },
        .{ "??", "e\u{301}", false },
        .{ "[!é]", "e\u{301}", false },
        .{ "[è-ê]", "e\u{301}", true },
        .{ "\\e\u{301}", "é", true },
        .{ "é*", "e\u{301}abc", true },
        .{ "e?", "é", false },
        .{ "?\u{301}", "é", false },
        .{ "[\\e\u{301}]", "é", true },
        .{ "각", "\u{1100}\u{1161}\u{11a8}", true },
        .{ "\u{212b}", "A\u{30a}", true },
        .{ "?", "\u{344}", false },
        .{ "??", "\u{344}", true },
        .{ "q\u{323}\u{307}", "q\u{307}\u{323}", true },
        .{ "\xff?", "\xffe\u{301}", true },
        .{ "\xff", "\xfe", false },
    };
    for (cases) |c| {
        try t.expectEqual(c[2], try sweep.match(c[0], c[1], options));
        var p = try sweep.Pattern.compile(t.allocator, c[0], options);
        defer p.deinit();
        try t.expectEqual(c[2], p.matches(c[1]));
        var b: sweep.Set.Builder = .init(t.allocator);
        defer b.deinit();
        _ = try b.add(c[0], .{ .options = options });
        var s = try b.build();
        defer s.deinit();
        var cache: sweep.Set.Cache = try .init(t.allocator, &s, .{});
        defer cache.deinit();
        try t.expectEqual(c[2], s.any(&cache, c[1], .file));
    }
    for ([_][]const u8{ "[\u{344}]", "[q\u{301}]", "[\u{958}]", "[a-\u{344}]" }) |p| {
        try t.expectError(error.InvalidPattern, sweep.Pattern.compile(t.allocator, p, options));
    }
    try t.expect(!try sweep.match("é", "e\u{301}", .{}));
    try t.expect(!try sweep.match("[é]", "e\u{301}", .{}));
}

fn codes(bytes: []const u8, out: []u21) []u21 {
    var it: normal.Iterator = .init(bytes, false);
    var n: usize = 0;
    while (it.next()) |cp| {
        out[n] = cp;
        n += 1;
    }
    return out[0..n];
}
fn encode(text: []const u8, out: []u8) ![]u8 {
    var parts = std.mem.tokenizeScalar(u8, text, ' ');
    var n: usize = 0;
    while (parts.next()) |part| {
        const cp = try std.fmt.parseInt(u21, part, 16);
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        @memcpy(out[n..][0..len], buf[0..len]);
        n += len;
    }
    return out[0..n];
}
test "NFC Unicode 18 complete normalization conformance corpus" {
    var lines = std.mem.splitScalar(u8, @embedFile("NormalizationTest.txt"), '\n');
    var rows: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        var bytes: [5][256]u8 = undefined;
        var values: [5][]u8 = undefined;
        for (&values, &bytes) |*v, *buf| v.* = try encode(fields.next().?, buf);
        var expected: [128]u21 = undefined;
        const want = codes(values[1], &expected);
        for (values[0..3]) |v| {
            var actual: [128]u21 = undefined;
            try t.expectEqualSlices(u21, want, codes(v, &actual));
        }
        const kwant = codes(values[3], &expected);
        for (values[3..5]) |v| {
            var actual: [128]u21 = undefined;
            try t.expectEqualSlices(u21, kwant, codes(v, &actual));
        }
        rows += 1;
    }
    try t.expect(rows > 19000);
}

test "NFC ancestor captures folding and mixed set policies" {
    var p = try sweep.Pattern.compile(t.allocator, "café/?", options);
    defer p.deinit();
    const subject = "cafe\u{301}/e\u{301}/child";
    try t.expectEqual(@as(?usize, "cafe\u{301}/e\u{301}".len), p.ancestor(subject));
    try t.expect(p.leadsTo("cafe\u{301}"));
    var cache = try p.captureCache(t.allocator);
    defer cache.deinit();
    var out: [1]?sweep.Pattern.Capture = undefined;
    try t.expect(try p.captures(&cache, "cafe\u{301}/e\u{301}", &out));
    try t.expectEqualStrings("e\u{301}", "cafe\u{301}/e\u{301}"[out[0].?.start..out[0].?.end]);
    var folded = options;
    folded.case = .unicode;
    try t.expect(try sweep.match("[É]", "e\u{301}", folded));
    var b: sweep.Set.Builder = .init(t.allocator);
    defer b.deinit();
    _ = try b.add("é", .{ .options = .{ .syntax = .glob } });
    _ = try b.add("é", .{ .options = options });
    var s = try b.build();
    defer s.deinit();
    var c: sweep.Set.Cache = try .init(t.allocator, &s, .{ .capacity = 256 });
    defer c.deinit();
    try t.expectEqual(@as(?u32, 1), s.first(&c, "e\u{301}", .file));
    var ancestors = s.ancestors(&c, "e\u{301}/x", .file);
    try t.expectEqual(@as(?u32, 1), ancestors.next().?.last);
}
test "NFC unbounded combining runs remain canonically ordered" {
    const long = shakedown.corpus.repeat("\u{315}\u{300}", 2048);
    var it: normal.Iterator = .init(long, false);
    for (0..2048) |_| try t.expectEqual(@as(?u21, 0x300), it.next());
    for (0..2048) |_| try t.expectEqual(@as(?u21, 0x315), it.next());
    try t.expectEqual(@as(?u21, null), it.next());
}

test "NFC alternate separators stay parsed syntax and original offsets" {
    const opts: sweep.Options = .{ .syntax = .{ .unit = .utf8, .escape = false, .alternate_separator = '\\' }, .normalization = .nfc, .anywhere = true };
    const rows = [_]struct { []const u8, []const u8, bool }{
        .{ "dir\\[é]", "dir/e\u{301}", true },
        .{ "dir/[é]", "dir\\e\u{301}", true },
        .{ "dir\\?", "other/dir/e\u{301}", false },
        .{ "[é]", "dir\\e\u{301}", true },
    };
    for (rows) |r| {
        try t.expectEqual(r[2], try sweep.match(r[0], r[1], opts));
        var p = try sweep.Pattern.compile(t.allocator, r[0], opts);
        defer p.deinit();
        try t.expectEqual(r[2], p.matches(r[1]));
    }
}

fn allocationCase(gpa: std.mem.Allocator) !void {
    var p = try sweep.Pattern.compile(gpa, "café/[é]", options);
    defer p.deinit();
    try t.expect(p.matches("cafe\u{301}/e\u{301}"));
    var b: sweep.Set.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.add("café/[é]", .{ .options = options });
    var s = try b.build();
    defer s.deinit();
    var c: sweep.Set.Cache = try .init(gpa, &s, .{ .capacity = 256 });
    defer c.deinit();
    try t.expect(s.any(&c, "cafe\u{301}/e\u{301}", .file));
}
test "NFC allocation failures leave no partial owner" {
    var no_resize: shakedown.alloc.NoResize = .init(t.allocator);
    try t.checkAllAllocationFailures(no_resize.allocator(), allocationCase, .{});
}
