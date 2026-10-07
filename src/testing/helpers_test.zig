//! `escape` against the matcher: an escaped literal matches itself.
const std = @import("std");
const sweep = @import("../sweep.zig");
const gen = @import("gen.zig");

fn escapeOne(s: gen.Source) anyerror!void {
    var text_buf: [24]u8 = undefined;
    const options = gen.options(s);
    const text = gen.string(s, &text_buf, &gen.any_text);
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    sweep.escape(&w, text, options.syntax) catch |err| switch (err) {
        error.Unrepresentable => {
            const quotable = options.syntax.escape or options.syntax.brackets != .none;
            try std.testing.expect(!quotable);
            return;
        },
        error.WriteFailed => unreachable,
    };
    const pattern = w.buffered();
    const matched = try sweep.match(pattern, text, options);
    if (!matched) {
        std.debug.print("escape: \"{f}\" -> \"{f}\" ({any})\n", .{ std.zig.fmtString(text), std.zig.fmtString(pattern), options });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(sweep.literalPrefix(pattern, options.syntax) == pattern.len, std.mem.eql(u8, pattern, text));
}

test "fuzz: an escaped literal matches itself" {
    try std.testing.fuzz({}, gen.fuzzed(escapeOne), .{});
}

test "an escaped literal matches itself on seeded inputs" {
    try gen.seeded(escapeOne, 0xe5c4_9e, 4000);
}

test "escape quotes with brackets when escapes are off" {
    var out: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try sweep.escape(&w, "a*b[c", .{ .escape = false });
    try std.testing.expectEqualStrings("a[*]b[[]c", w.buffered());
    try std.testing.expect(try sweep.match(w.buffered(), "a*b[c", .{ .syntax = .{ .escape = false } }));
    w = .fixed(&out);
    try std.testing.expectError(error.Unrepresentable, sweep.escape(&w, "a*", .{ .escape = false, .brackets = .none }));
}
