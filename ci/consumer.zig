//! What a project that depends on sweep and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so sweep's
//! build.zig must work without any of its own CI dependencies.
const sweep = @import("sweep");

pub fn main() void {
    _ = sweep.match("*.zig", "a.zig", .{}) catch false;
}
