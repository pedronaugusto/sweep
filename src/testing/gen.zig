//! Input generators for the differential and property tests: patterns and
//! subjects built from pieces that exercise every rule, and random options.
//! They draw from a shakedown `Source`, which `check` gives each case.
const sweep = @import("../glob.zig");
const shake = @import("shakedown");

/// Where choices come from.
pub const Source = shake.Source;

/// A number below `n`, which must not be zero.
pub fn index(s: *Source, n: usize) usize {
    return shake.gen.intRange(s, usize, 0, n - 1);
}

/// True about once in `n`.
pub fn oneIn(s: *Source, n: u32) bool {
    return s.chance(1_000_000 / n);
}

pub fn value(s: *Source, comptime T: type) T {
    return switch (@typeInfo(T)) {
        .bool => shake.gen.boolean(s),
        .@"enum" => shake.gen.enumValue(s, T),
        else => shake.gen.int(s, T),
    };
}

/// Pattern pieces for the git dialects.
pub const git_pattern = [_][]const u8{
    "a",         "b",         "/",         "*",         "**",    "?",   "[",   "]", "!", "^", "-", ":", "\\", ".", "A",
    "[:alpha:]", "[:upper:]", "[:lower:]", "[:digit:]", "[a-c]", "**/", "/**",
};

/// Subject pieces for the git dialects.
pub const git_text = [_][]const u8{ "a", "b", "/", ".", "A", "-", "]", "[", "\\", "*", "?", ":", "!", "B" };

/// Pattern pieces for every dialect: braces and UTF-8 too.
pub const any_pattern = git_pattern ++ [_][]const u8{ "{", "}", ",", "{a,b}", "{,", "\xc3\xa9", "\xff", ".", "/." };

/// Subject pieces for every dialect.
pub const any_text = git_text ++ [_][]const u8{ "\xc3\xa9", "\xff", "\xc3", ",", "{", "}" };

/// A string of pieces, cut to fit `buf`.
pub fn string(s: *Source, buf: []u8, pieces: []const []const u8) []u8 {
    var len: usize = 0;
    while (s.more(7)) {
        const piece = pieces[index(s, pieces.len)];
        if (len + piece.len > buf.len) break;
        @memcpy(buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buf[0..len];
}

/// Random options: every syntax field, case and `anywhere`.
pub fn options(s: *Source) sweep.Options {
    const separators = [_]?u8{ '/', '/', null, '.' };
    return .{
        .syntax = .{
            .separator = separators[index(s, separators.len)],
            .globstar = value(s, sweep.Syntax.Globstar),
            .escape = value(s, bool),
            .brackets = value(s, sweep.Syntax.Brackets),
            .braces = value(s, bool),
            .unit = value(s, sweep.Syntax.Unit),
            .leading_dot = value(s, sweep.Syntax.LeadingDot),
        },
        .case = ([_]sweep.Case{ .sensitive, .ascii, .ascii_git })[index(s, 3)],
        .anywhere = value(s, bool),
    };
}
