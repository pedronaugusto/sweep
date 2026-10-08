//! `zig run tools/casefold.zig > src/fold.zig`; Unicode C + S mappings only.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const w = &stdout.interface;
    try w.writeAll("//! Generated from Unicode 18.0.0 CaseFolding.txt by tools/casefold.zig.\n//! Unicode data license: src/UNICODE-LICENSE.txt (Unicode-3.0).\n\n/// One default simple case-fold mapping.\npub const Pair = struct { from: u21, to: u21 };\n/// C and S mappings, sorted by source scalar.\npub const pairs = [_]Pair{\n");
    var lines = std.mem.splitScalar(u8, @embedFile("CaseFolding.txt"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const from = std.mem.trim(u8, fields.next().?, " ");
        const status = std.mem.trim(u8, fields.next().?, " ");
        if (!std.mem.eql(u8, status, "C") and !std.mem.eql(u8, status, "S")) continue;
        const to = std.mem.trim(u8, fields.next().?, " ");
        const a = try std.fmt.parseInt(u21, from, 16);
        const b = try std.fmt.parseInt(u21, to, 16);
        try w.print("    .{{ .from = 0x{x}, .to = 0x{x} }},\n", .{ a, b });
    }
    try w.writeAll("};\n");
    try w.flush();
}
