//! A consumer imports the one module and reaches every part using only runtime dependencies.
const sweep = @import("sweep");

pub fn main() void {
    comptime {
        if (sweep.Pattern != sweep.glob.Pattern or sweep.Set != sweep.glob.Set) @compileError("glob identity differs");
        if (sweep.Walk != sweep.walk.Walk) @compileError("walk identity differs");
    }
    _ = sweep.glob.match("*.zig", "a.zig", .{}) catch false;
    _ = sweep.glob.Set.Index.fromRaw(1);
    _ = sweep.glob.Set.Bytes.fromRaw(65536);
}
