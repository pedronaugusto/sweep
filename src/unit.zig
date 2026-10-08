//! Units: what one `?` or one bracket consumes, and how letters fold.
//!
//! A unit is a code. In byte mode it is the byte. In UTF-8 mode a well-formed
//! scalar is its value, and each byte of an ill-formed or truncated sequence
//! is `ill_formed + byte`, a code no scalar has.
const std = @import("std");

/// A unit's code.
pub const Code = u21;

/// The first code of an ill-formed byte: one past the last scalar.
pub const ill_formed: Code = 0x110000;

/// One unit read from a byte string.
pub const Unit = struct {
    code: Code,
    /// Bytes it spans, 1 to 4.
    len: u3,
};

/// Reads the unit at `bytes[at]`, which must exist.
pub fn decode(utf8: bool, bytes: []const u8, at: usize) Unit {
    const first = bytes[at];
    if (!utf8 or first < 0x80) return .{ .code = first, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(first) catch return illFormed(first);
    if (len > bytes.len - at) return illFormed(first);
    const scalar = switch (len) {
        2 => std.unicode.utf8Decode2(bytes[at..][0..2].*),
        3 => std.unicode.utf8Decode3(bytes[at..][0..3].*),
        4 => std.unicode.utf8Decode4(bytes[at..][0..4].*),
        else => return illFormed(first),
    } catch return illFormed(first);
    return .{ .code = scalar, .len = len };
}

fn illFormed(byte: u8) Unit {
    return .{ .code = ill_formed + byte, .len = 1 };
}

/// The code a separator byte has as a unit: the byte itself, or in UTF-8
/// mode an ill-formed unit when the byte is not ASCII.
pub fn separatorCode(utf8: bool, separator: u8) u21 {
    return if (utf8 and separator >= 0x80) ill_formed + separator else separator;
}

/// How many units `bytes` holds.
pub fn count(utf8: bool, bytes: []const u8) usize {
    if (!utf8) return bytes.len;
    var at: usize = 0;
    var units: usize = 0;
    while (at < bytes.len) : (units += 1) at += decode(true, bytes, at).len;
    return units;
}

/// A-Z to a-z; every other code unchanged.
pub fn fold(code: u21) u21 {
    return if (isUpper(code)) code + ('a' - 'A') else code;
}

/// a-z to A-Z and A-Z to a-z; every other code unchanged.
pub fn swapCase(code: u21) u21 {
    if (isUpper(code)) return code + ('a' - 'A');
    if (isLower(code)) return code - ('a' - 'A');
    return code;
}

pub fn isUpper(code: u21) bool {
    return code >= 'A' and code <= 'Z';
}

pub fn isLower(code: u21) bool {
    return code >= 'a' and code <= 'z';
}

test "ill-formed bytes are one unit each and equal no scalar" {
    const bytes = "a\xc3\xa9\xff\xe2\x82";
    var at: usize = 0;
    var codes: [8]Code = undefined;
    var n: usize = 0;
    while (at < bytes.len) : (n += 1) {
        const unit = decode(true, bytes, at);
        codes[n] = unit.code;
        at += unit.len;
    }
    try std.testing.expectEqualSlices(Code, &.{ 'a', 0xe9, ill_formed + 0xff, ill_formed + 0xe2, ill_formed + 0x82 }, codes[0..n]);
    try std.testing.expectEqual(@as(usize, 5), count(true, bytes));
    try std.testing.expectEqual(@as(usize, 6), count(false, bytes));
}

test "overlong forms and surrogates are ill-formed" {
    try std.testing.expectEqual(ill_formed + 0xc0, decode(true, "\xc0\xaf", 0).code);
    try std.testing.expectEqual(ill_formed + 0xed, decode(true, "\xed\xa0\x80", 0).code);
    try std.testing.expectEqual(ill_formed + 0xf4, decode(true, "\xf4\x90\x80\x80", 0).code);
}

/// Whether a string needs no scalar decoding or composition.
pub fn isAscii(bytes: []const u8) bool {
    for (bytes) |b| if (b >= 0x80) return false;
    return true;
}
