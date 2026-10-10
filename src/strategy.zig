//! Literal strategies: patterns whose language a few byte comparisons
//! decide, recognised from the compiled automaton so they agree with it by
//! construction, and the literal prefix and suffix every other pattern
//! requires.
const std = @import("std");
const unit = @import("unit.zig");
const program_mod = @import("program.zig");

const Program = program_mod.Program;
const Allocator = std.mem.Allocator;

/// How a pattern is decided without its automaton.
pub const Kind = enum {
    /// The subject is the literal.
    exact,
    /// The subject starts with the literal (`lit/**`, a text-mode `lit*`, `**`).
    starts,
    /// The subject starts with the literal and has no separator after it (`dir/lit*`).
    starts_component,
    /// The subject ends with the literal, which holds no separator (`**/*lit`).
    ends,
    /// The subject is the literal or ends with a separator and the literal (`**/lit`).
    tail,
    /// The last component starts with the literal (`**/lit*`).
    basename_starts,
    /// The subject holds the literal, which starts and ends with a separator,
    /// or starts with it less its first separator (`**/lit/**`).
    within,
};

pub const Strategy = struct {
    kind: Kind,
    /// Canonical bytes: folded when the reading folds.
    literal: []const u8,

    /// Whether `subject` matches, under `reading`.
    pub fn matches(s: Strategy, reading: program_mod.Reading, subject: []const u8) bool {
        const lit = s.literal;
        return switch (s.kind) {
            .exact => subject.len == lit.len and eql(reading, subject, lit),
            .starts => subject.len >= lit.len and eql(reading, subject[0..lit.len], lit),
            .starts_component => subject.len >= lit.len and eql(reading, subject[0..lit.len], lit) and
                std.mem.findScalar(u8, subject[lit.len..], separatorByte(reading)) == null,
            .ends => subject.len >= lit.len and eql(reading, subject[subject.len - lit.len ..], lit),
            .tail => tail(reading, subject, lit),
            .within => within(reading, subject, lit),
            .basename_starts => blk: {
                const start = if (std.mem.findScalarLast(u8, subject, separatorByte(reading))) |at| at + 1 else 0;
                const base = subject[start..];
                break :blk base.len >= lit.len and eql(reading, base[0..lit.len], lit);
            },
        };
    }
};

fn within(reading: program_mod.Reading, subject: []const u8, lit: []const u8) bool {
    const inner = lit[1..];
    if (subject.len >= inner.len and eql(reading, subject[0..inner.len], inner)) return true;
    if (!reading.fold) return contains(subject, lit);
    var at: usize = 0;
    while (at + lit.len <= subject.len) : (at += 1) {
        if (eql(reading, subject[at..][0..lit.len], lit)) return true;
    }
    return false;
}

/// Whether `subject` holds `needle`, which has at least two bytes. Blocks
/// are tested for the first two bytes together: a separator followed by a
/// letter is rare enough that the checks that follow seldom run, where a
/// loop over the bytes mispredicts at every separator.
fn contains(subject: []const u8, needle: []const u8) bool {
    if (subject.len < needle.len) return false;
    const last = subject.len - needle.len;
    var at: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |n| {
        const first: @Vector(n, u8) = @splat(needle[0]);
        const second: @Vector(n, u8) = @splat(needle[1]);
        // A block's bytes and the ones after them are all in the subject.
        while (at + n < subject.len) : (at += n) {
            const here: @Vector(n, u8) = subject[at..][0..n].*;
            const next: @Vector(n, u8) = subject[at + 1 ..][0..n].*;
            var starts: @Int(.unsigned, n) = @bitCast((here == first) & (next == second));
            while (starts != 0) : (starts &= starts - 1) {
                const found = at + @ctz(starts);
                if (found <= last and std.mem.eql(u8, subject[found..][0..needle.len], needle)) return true;
            }
        }
    }
    while (at <= last) : (at += 1) {
        if (subject[at] == needle[0] and std.mem.eql(u8, subject[at..][0..needle.len], needle)) return true;
    }
    return false;
}

fn tail(reading: program_mod.Reading, subject: []const u8, lit: []const u8) bool {
    if (subject.len < lit.len or !eql(reading, subject[subject.len - lit.len ..], lit)) return false;
    return subject.len == lit.len or subject[subject.len - lit.len - 1] == separatorByte(reading);
}

/// The separator as a byte; strategies are only chosen when it is ASCII.
pub fn separatorByte(reading: program_mod.Reading) u8 {
    return @intCast(reading.separator.?);
}

/// Whether `subject`, folded as the reading says, equals canonical `lit`.
pub fn eql(reading: program_mod.Reading, subject: []const u8, lit: []const u8) bool {
    if (!reading.fold) return std.mem.eql(u8, subject, lit);
    for (subject, lit) |a, b| if (std.ascii.toLower(a) != b) return false;
    return true;
}

/// What a program's nodes say about literals, before any bytes are kept.
pub const Shape = struct {
    strategy: ?Kind = null,
    /// Node range of the strategy's literal.
    first: usize = 0,
    end: usize = 0,
    /// Node ranges of the required prefix and suffix, when no strategy.
    head: usize = 0,
    tail_start: usize = 0,
};

/// Whether every literal node in `p` can be written as canonical bytes that
/// byte comparisons decide exactly.
fn bytesExact(p: Program) bool {
    const r = p.reading;
    if (r.leading_dot) return false;
    if (r.separator) |s| if (s >= 0x80) return false;
    for (p.nodes) |node| switch (node.op) {
        .lit => {
            if (node.arg >= unit.ill_formed) return false;
            if (r.fold and unit.isUpper(@intCast(node.arg))) return false;
        },
        .split, .jump, .class, .any, .dot, .dot_plain => return false,
        .gstar => if (node.arg != 0) return false,
        else => {},
    };
    return true;
}

/// Recognises a strategy in a one-entry program (ending in its accept).
pub fn recognise(p: Program) Shape {
    var shape: Shape = .{};
    if (p.reading.alternate_separator != null or p.reading.nfc or p.reading.unicode) return .{ .tail_start = p.nodes.len - 1 };
    const nodes = p.nodes[0 .. p.nodes.len - 1];
    shape.head = literalRun(nodes, 0);
    shape.tail_start = tailRun(nodes, shape.head);
    if (!bytesExact(p)) return shape;
    const n = nodes.len;
    const isLit = struct {
        fn f(node: program_mod.Node) bool {
            return node.op == .lit or node.op == .sep;
        }
    }.f;
    var lits: usize = 0;
    while (lits < n and isLit(nodes[lits])) lits += 1;
    if (lits == n) return .{ .strategy = .exact, .first = 0, .end = n };
    // `lit/**`, `**`, and a text-mode `lit*`.
    if (lits == n - 1) {
        const last = nodes[n - 1];
        const after_sep = lits > 0 and nodes[lits - 1].op == .sep;
        if (last.op == .gstar and (lits == 0 or after_sep)) return .{ .strategy = .starts, .first = 0, .end = lits };
        if (last.op == .star and last.arg == 1) return .{ .strategy = .starts, .first = 0, .end = lits };
        if (last.op == .star and last.arg == 0) return .{ .strategy = .starts_component, .first = 0, .end = lits };
    }
    // `**/…`: a globstar, its separator unescaped, then literals.
    if (n >= 3 and nodes[0].op == .gstar and nodes[1].op == .sep and nodes[1].arg == 0) {
        var rest: usize = 2;
        if (nodes[2].op == .star and nodes[2].arg == 0) {
            rest = 3;
            var j = rest;
            while (j < n and nodes[j].op == .lit) j += 1;
            if (j == n and j > rest) return .{ .strategy = .ends, .first = rest, .end = n };
            // `**/*`: every subject.
            if (n == 3) return .{ .strategy = .starts, .first = 0, .end = 0 };
            return shape;
        }
        var j = rest;
        while (j < n and isLit(nodes[j])) j += 1;
        if (j == n - 1 and j > rest and nodes[n - 1].op == .star and nodes[n - 1].arg == 0 and allLiterals(nodes[rest..j]))
            return .{ .strategy = .basename_starts, .first = rest, .end = j };
        if (j == n and j > rest and nodes[rest].op != .sep) return .{ .strategy = .tail, .first = rest, .end = n };
    }
    // `**/lit/**`: whole components, then anything.
    if (n >= 5 and nodes[0].op == .gstar and nodes[1].op == .sep and nodes[1].arg == 0 and nodes[2].op != .sep and nodes[n - 2].op == .sep and nodes[n - 2].arg == 0 and nodes[n - 1].op == .gstar) {
        var j: usize = 2;
        while (j < n - 1 and isLit(nodes[j])) j += 1;
        if (j == n - 1) return .{ .strategy = .within, .first = 1, .end = n - 1 };
    }
    // A text-mode `*lit`.
    if (n >= 2 and nodes[0].op == .star and nodes[0].arg == 1) {
        var j: usize = 1;
        while (j < n and nodes[j].op == .lit) j += 1;
        if (j == n) return .{ .strategy = .ends, .first = 1, .end = n };
    }
    return shape;
}

fn allLiterals(nodes: []const program_mod.Node) bool {
    for (nodes) |node| if (node.op != .lit) return false;
    return true;
}

/// The literal nodes from `from` on, before the first that is not one.
fn literalRun(nodes: []const program_mod.Node, from: usize) usize {
    var i = from;
    while (i < nodes.len) : (i += 1) switch (nodes[i].op) {
        .lit, .sep => {},
        .dot => i += 1,
        else => break,
    };
    return i;
}

/// Where the trailing run of literal nodes begins, not before `floor`. A
/// separator right after a globstar may consume nothing, so it ends the run.
fn tailRun(nodes: []const program_mod.Node, floor: usize) usize {
    for (nodes) |node| if (node.op == .split or node.op == .jump) return nodes.len;
    var i = nodes.len;
    while (i > floor) {
        const node = nodes[i - 1];
        switch (node.op) {
            .lit => {},
            .dot_plain => i -= 1,
            .sep => if (i >= 2 and nodes[i - 2].op == .gstar) break,
            else => break,
        }
        i -= 1;
    }
    return i;
}

/// Appends the canonical bytes of the literal nodes `first..end`.
pub fn bytes(gpa: Allocator, p: Program, first: usize, end: usize, out: *std.ArrayList(u8)) Allocator.Error!void {
    var i = first;
    while (i < end) : (i += 1) {
        const node = p.nodes[i];
        const code: unit.Code = switch (node.op) {
            .lit => @intCast(node.arg),
            .sep => p.reading.separator.?,
            .dot => '.',
            .dot_plain => continue,
            else => unreachable,
        };
        try encode(gpa, p.reading.utf8, code, out);
    }
}

/// Appends the bytes of one unit code.
pub fn encode(gpa: Allocator, utf8: bool, code: unit.Code, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (!utf8 or code < 0x80) return out.append(gpa, @intCast(code));
    if (code >= unit.ill_formed) return out.append(gpa, @intCast(code - unit.ill_formed));
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &buf) catch unreachable; // unreachable: a decoded scalar encodes
    try out.appendSlice(gpa, buf[0..len]);
}

/// The canonical bytes of the literal nodes `first..end` written into
/// `buf`, or null when they do not fit.
pub fn bytesInto(p: Program, first: usize, end: usize, buf: []u8) ?[]u8 {
    var len: usize = 0;
    var i = first;
    while (i < end) : (i += 1) {
        const node = p.nodes[i];
        const code: unit.Code = switch (node.op) {
            .lit => @intCast(node.arg),
            .sep => p.reading.separator.?,
            .dot => '.',
            .dot_plain => continue,
            else => unreachable,
        };
        var one: [4]u8 = undefined;
        const n: usize = if (!p.reading.utf8 or code < 0x80) one: {
            one[0] = @intCast(code);
            break :one 1;
        } else if (code >= unit.ill_formed) one: {
            one[0] = @intCast(code - unit.ill_formed);
            break :one 1;
        } else std.unicode.utf8Encode(code, &one) catch unreachable; // unreachable: a decoded scalar encodes
        if (len + n > buf.len) return null;
        @memcpy(buf[len..][0..n], one[0..n]);
        len += n;
    }
    return buf[0..len];
}
