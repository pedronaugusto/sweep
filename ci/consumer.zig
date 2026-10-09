//! A consumer imports the facade and either concern using only runtime dependencies.
const sweep = @import("sweep");
const glob = @import("sweep.glob");
const walk = @import("sweep.walk");

pub fn main() void {
    comptime {
        if (sweep.Pattern != glob.Pattern or sweep.Set != glob.Set) @compileError("glob identity differs");
        if (sweep.Walk != walk.Walk) @compileError("walk identity differs");
    }
    _ = glob.match("*.zig", "a.zig", .{}) catch false;
    _ = glob.Set.Index.fromRaw(1);
    _ = glob.Set.Bytes.fromRaw(65536);
}
