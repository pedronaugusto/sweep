const std = @import("std");
const program = @import("program.zig");
const Set = @import("set.zig").Set;
const Options = @import("syntax.zig").Options;
const NoResize = @import("shakedown").alloc.NoResize;

test "W4 conservative construction bounds preserve representable programs" {
    var backing: NoResize = .init(std.testing.allocator);
    const gpa = backing.allocator();
    const pattern = try gpa.alloc(u8, 131_100);
    defer gpa.free(pattern);
    @memset(pattern, '{');
    const options: Options = .{ .syntax = .editorconfig };
    const bounds = try program.Bounds.of(pattern, options);
    try std.testing.expect(bounds.nodes.raw() > program.Node.max_arg);
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    try std.testing.expectError(error.InvalidPattern, builder.add("{", .{ .options = .{ .syntax = .glob } }));
    try std.testing.expectEqual(@as(u32, 0), (try builder.add("ok", .{})).raw());
}

test "W4 combined bounds preserve their owner on arithmetic failure" {
    var arithmetic: program.Bounds = .{ .ranges = .fromRaw(std.math.maxInt(usize)) };
    try std.testing.expectError(error.PatternTooLong, arithmetic.append(.{ .ranges = .fromRaw(1) }));
    try std.testing.expectEqual(std.math.maxInt(usize), arithmetic.ranges.raw());
    try std.testing.expectEqual(@as(usize, 0), arithmetic.nodes.raw());
}

test "W4 semantic domains retain scalar and packed instruction layouts" {
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(Set.Index));
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(Set.Count));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(Set.Bytes));
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(program.Node));
    try std.testing.expectEqual(@as(usize, 4 * @sizeOf(usize)), @sizeOf(program.Bounds));
}
