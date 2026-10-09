//! The public scalar mapping shares the matcher's one Unicode owner.
const std = @import("std");
const sweep = @import("../glob.zig");
const unicode = @import("../unicode.zig");
const shake = @import("shakedown");

test "public simple folding covers every table mapping" {
    for (unicode.pairs) |pair| {
        try std.testing.expectEqual(pair.to, sweep.foldCase(pair.from));
        try std.testing.expectEqual(pair.to, sweep.foldCase(pair.to));
    }
}

fn stable(_: void, c: *shake.Case) !void {
    const code = shake.gen.intRange(c.source, u21, 0, 0x1fffff);
    const folded = sweep.foldCase(code);
    try std.testing.expectEqual(folded, sweep.foldCase(folded));
    if (code > 0x10ffff) try std.testing.expectEqual(code, folded);
}

test "public simple folding is idempotent and keeps raw byte codes" {
    try shake.check(std.testing.allocator, {}, stable, .{ .cases = 10000 });
    try std.testing.expectEqual(@as(u21, 0xe9), sweep.foldCase(0xc9));
    try std.testing.expectEqual(@as(u21, 0xdf), sweep.foldCase(0xdf));
    try std.testing.expectEqual(@as(u21, 0x130), sweep.foldCase(0x130));
    try std.testing.expectEqual(@as(u21, 0x3c3), sweep.foldCase(0x3c2));
}
