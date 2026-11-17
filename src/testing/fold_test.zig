//! The public scalar mapping shares the matcher's one Unicode owner.
const std = @import("std");
const sweep = @import("../glob.zig");
const unicode = @import("../unicode.zig");
const shake = @import("shakedown");
const xenoglyph = @import("xenoglyph");

test "public simple folding is the matcher's on every code" {
    var code: u21 = 0;
    while (code <= 0x1100ff) : (code += 1) try std.testing.expectEqual(unicode.fold(code), sweep.foldCase(code));
}

/// A scalar `[lo-hi]` can be written with: no surrogate, no ASCII syntax.
fn writable(code: u21) u21 {
    return if (code >= 0xd800 and code < 0xe000) 0xe000 else @max(code, 0x80);
}

/// Under `.unicode`, `[lo-hi]` matches `x` exactly when some member of the
/// range folds as `x` does: the class closes under folding, and no further.
fn closedRange(_: void, c: *shake.Case) !void {
    // Half the ranges start just before a code that folds with another.
    const start = shake.gen.intRange(c.source, u21, 0x80, 0x10ffff);
    const near = if (shake.gen.boolean(c.source)) unicode.nextFolding(start) orelse start else start;
    const lo = writable(near -| shake.gen.intRange(c.source, u21, 0, 4));
    const hi = writable(@min(0x10ffff, lo + shake.gen.intRange(c.source, u21, 0, 300)));
    if (hi < lo or (lo < 0xe000 and hi >= 0xd800)) return;
    var pattern: [11]u8 = undefined;
    pattern[0] = '[';
    var len: usize = 1;
    len += try std.unicode.utf8Encode(lo, pattern[len..]);
    pattern[len] = '-';
    len += 1;
    len += try std.unicode.utf8Encode(hi, pattern[len..]);
    pattern[len] = ']';
    len += 1;
    var p: sweep.Pattern = try .compile(std.testing.allocator, pattern[0..len], .{ .syntax = .glob, .case = .unicode });
    defer p.deinit();
    // Every member, its fold, everything folding with it, and the codes
    // just outside the range.
    var member = lo;
    while (member <= hi) : (member += 1) {
        try probe(&p, lo, hi, member);
        try probe(&p, lo, hi, unicode.fold(member));
        for (xenoglyph.case.simpleFoldOrbit(member)) |other| try probe(&p, lo, hi, other);
    }
    try probe(&p, lo, hi, lo - 1);
    if (hi < 0x10ffff) try probe(&p, lo, hi, hi + 1);
}

fn probe(p: *sweep.Pattern, lo: u21, hi: u21, x: u21) !void {
    if (x >= 0xd800 and x < 0xe000) return;
    var expected = false;
    var member = lo;
    while (member <= hi) : (member += 1) {
        if (unicode.fold(member) == unicode.fold(x)) expected = true;
    }
    var subject: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(x, &subject);
    try std.testing.expectEqual(expected, p.matches(subject[0..len]));
}

test "a folded bracket range matches what folds as a member does, and nothing else" {
    try shake.check(std.testing.allocator, {}, closedRange, .{ .cases = 400 });
    const o: sweep.Options = .{ .syntax = .glob, .case = .unicode };
    // KELVIN SIGN alone brings k in; a range of Greek capitals brings their small letters and final sigma.
    try std.testing.expect(try sweep.match("[\u{212a}-\u{212a}]", "k", o));
    try std.testing.expect(try sweep.match("[Α-Ω]", "ς", o));
    try std.testing.expect(!try sweep.match("[Α-Ρ]", "σ", o));
}

fn stable(_: void, c: *shake.Case) !void {
    const code = shake.gen.intRange(c.source, u21, 0, 0x1fffff);
    const folded = sweep.foldCase(code);
    try std.testing.expectEqual(folded, sweep.foldCase(folded));
    if (code > 0x10ffff) try std.testing.expectEqual(code, folded);
}

test "public simple folding is idempotent and keeps raw byte codes" {
    try shake.check(std.testing.allocator, {}, stable, .{ .cases = 10000 });
    try std.testing.expectEqual(@as(u21, 0xe9), sweep.foldCase(0xc9));
    try std.testing.expectEqual(@as(u21, 0xdf), sweep.foldCase(0xdf));
    try std.testing.expectEqual(@as(u21, 0x130), sweep.foldCase(0x130));
    try std.testing.expectEqual(@as(u21, 0x3c3), sweep.foldCase(0x3c2));
}
