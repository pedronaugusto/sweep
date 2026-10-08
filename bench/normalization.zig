//! Exact and NFC composed-scalar matching, measured through shakedown.
const std = @import("std");
const sweep = @import("sweep");
const shakedown = @import("shakedown");
const Context = struct {
    pattern: sweep.Pattern,
    subject: []const u8,
    fn run(c: *Context, n: u64) !void {
        var hits: usize = 0;
        for (0..n) |_| {
            hits += @intFromBool(c.pattern.matches(c.subject));
            std.mem.doNotOptimizeAway(&c.pattern);
        }
        std.mem.doNotOptimizeAway(hits);
    }
};
pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: sweep.Options = .{ .syntax = .glob };
    var smoke = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--nfc")) {
            if (@hasField(sweep.Options, "normalization")) options.normalization = .nfc;
        } else if (std.mem.eql(u8, arg, "--smoke")) smoke = true else return error.UnknownArgument;
    }
    const rows = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "ascii", "src/**/[a-z]*.zig", "src/a/b/main.zig" },
        .{ "accent", "**/[é]*.zig", "src/cafe\u{301}/e\u{301}tude.zig" },
        .{ "hangul", "**/각?.zig", "src/\u{1100}\u{1161}\u{11a8}x.zig" },
        .{ "combining", "q\u{323}\u{307}*", "q\u{307}\u{323}abcdef" },
    };
    for (rows) |r| {
        var c: Context = .{ .pattern = try sweep.Pattern.compile(init.gpa, r[1], options), .subject = r[2] };
        defer c.pattern.deinit();
        try shakedown.bench.run(init.gpa, init.io, &out.interface, &c, &.{.{ .name = r[0], .unit = "query", .run = Context.run }}, .{ .commit = "normalization-seam" }, .{ .smoke = smoke });
    }
    try out.interface.flush();
}
