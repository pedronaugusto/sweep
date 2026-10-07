//! sweep has no OS calls: this object builds for wasm32-freestanding in
//! `zig build check-freestanding`.
const sweep = @import("sweep");

export fn sweepMatch(pattern: [*]const u8, pattern_len: usize, subject: [*]const u8, subject_len: usize) i32 {
    const matched = sweep.match(pattern[0..pattern_len], subject[0..subject_len], .{ .syntax = .glob }) catch return -1;
    return @intFromBool(matched);
}
