//! Decimal interval compilation, bounded by the number of digits rather
//! than the number of integers. Aligned blocks share their last digit range.
const std = @import("std");
const program = @import("program.zig");

// aegis: design: docs/design.md#safety-boundaries; parseInt checks both signed bounds in every mode and read rejects descending intervals.
pub const Interval = struct { lo: i64, hi: i64, end: usize };
pub const ReadError = error{InvalidRange};

/// An integer interval at `open`, or null for an ordinary brace group.
pub fn read(text: []const u8, open: usize) ReadError!?Interval {
    var at = open + 1;
    const first = at;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;
    const digits = at;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {}
    if (at == digits or at + 2 > text.len or !std.mem.eql(u8, text[at..][0..2], "..")) return null;
    const middle = at;
    at += 2;
    const second = at;
    if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;
    const more = at;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {}
    if (at == more or at == text.len or text[at] != '}') return null;
    const lo = std.fmt.parseInt(i64, text[first..middle], 10) catch return error.InvalidRange;
    const hi = std.fmt.parseInt(i64, text[second..at], 10) catch return error.InvalidRange;
    if (lo > hi) return error.InvalidRange;
    return .{ .lo = lo, .hi = hi, .end = at + 1 };
}

pub const CompileError = program.Builder.Full;

/// Appends a forward-only automaton for canonical decimal spellings,
/// with optional `+` for nonnegative integers and `-` for negative ones.
pub fn compile(b: *program.Builder, interval: Interval) CompileError!void {
    var compiler: Compiler = .{ .b = b };
    if (interval.lo < 0) try compiler.magnitude('-', @intCast(-@as(i128, @min(interval.hi, -1))), @intCast(-@as(i128, interval.lo)));
    if (interval.hi >= 0) {
        const lo: u64 = @intCast(@max(interval.lo, 0));
        try compiler.magnitude(null, lo, @intCast(interval.hi));
        try compiler.magnitude('+', lo, @intCast(interval.hi));
        if (lo == 0) try compiler.magnitude('-', 0, 0);
    }
    const end = b.node_len;
    if (compiler.split) |split| b.nodes[split.raw()] = .{ .op = .jump, .arg = @intCast(split.raw() + 1) }; // safe: split precedes its emitted branch
    var jump = compiler.jumps;
    while (jump != program.no_jump) {
        const next = program.Position.fromRaw(b.nodes[jump.raw()].arg);
        b.nodes[jump.raw()].arg = @intCast(end); // safe: emit bounded every appended node
        jump = next;
    }
}

const Compiler = struct {
    b: *program.Builder,
    split: ?program.Position = null,
    jumps: program.Position = program.no_jump,
    // aegis: no-danger: docs/design.md#safety-boundaries; these private values index only the interned decimal classes.
    digits: [10][10]?u32 = @splat(@splat(null)),

    fn branch(c: *Compiler) CompileError!void {
        if (c.split) |split| {
            const jump = try c.b.emit(.jump, @intCast(c.jumps.raw())); // safe: emitted jump position or max_arg sentinel
            c.jumps = jump;
            c.b.nodes[split.raw()].arg = @intCast(c.b.node_len); // safe: emit bounded every appended node
        }
        c.split = try c.b.emit(.split, 0);
    }

    fn digit(c: *Compiler, lo: u8, hi: u8) CompileError!void {
        if (lo == hi) {
            _ = try c.b.emit(.lit, lo);
            return;
        }
        if (c.digits[lo - '0'][hi - '0']) |id| {
            _ = try c.b.emit(.class, @intCast(id));
            return;
        }
        if (c.b.class_len == c.b.classes.len) return error.Full;
        var class: program.Class = .{};
        for (lo..@as(usize, hi) + 1) |byte| class.setLow(@intCast(byte));
        const id = c.b.class_len;
        c.b.classes[id] = class;
        c.b.class_len += 1;
        c.digits[lo - '0'][hi - '0'] = @intCast(id);
        _ = try c.b.emit(.class, @intCast(id));
    }

    // aegis: measured-boundary: docs/design.md#safety-boundaries; read validates signed endpoints; magnitudes stay within 0..2^63 and each step checks remaining room.
    fn magnitude(c: *Compiler, sign: ?u8, low: u64, high: u64) CompileError!void {
        var cur = low;
        while (cur <= high) {
            var size: u64 = 1;
            var zeros: usize = 0;
            // Never give a spelling a leading zero. Zero stands alone.
            if (cur != 0) while (size <= std.math.maxInt(u64) / 10 and cur % (size * 10) == 0 and size * 10 - 1 <= high - cur) {
                size *= 10;
                zeros += 1;
            };
            const quotient = cur / size;
            const last = @min(9, quotient % 10 + (high - cur + 1) / size - 1);
            try c.branch();
            if (sign) |s| _ = try c.b.emit(.lit, s);
            var buf: [20]u8 = undefined;
            const prefix = std.mem.print(&buf, "{d}", .{quotient / 10}) catch unreachable; // unreachable: u64 has at most twenty digits
            if (quotient >= 10) {
                for (prefix) |byte| _ = try c.b.emit(.lit, byte);
            }
            try c.digit('0' + @as(u8, @intCast(quotient % 10)), '0' + @as(u8, @intCast(last)));
            for (0..zeros) |_| try c.digit('0', '9');
            const step = (last - quotient % 10 + 1) * size;
            if (step > high - cur) break;
            cur += step;
        }
    }
};
