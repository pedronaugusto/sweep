const std = @import("std");
const sweep = @import("sweep");

pub fn main() !void {
    // --- README:usage ---
    // git's dialect: `*` stays in one component, `**/` spans any number.
    std.debug.assert(try sweep.match("src/**/*.zig", "src/a/b/c.zig", .{}));
    std.debug.assert(!try sweep.match("src/*.zig", "src/a/c.zig", .{}));
    // gitignore's rule for a pattern with no separator: any depth.
    std.debug.assert(try sweep.match("*.o", "build/x/y.o", .{ .anywhere = true }));
    // --- README:usage ---
}
