//! Input generators for the differential and property tests: patterns and
//! subjects built from pieces that exercise every rule, and random options.
//! They draw from the fuzzer's `Smith` under `--fuzz`, and from a seeded
//! generator in every `zig build test`.
const std = @import("std");
const sweep = @import("../sweep.zig");

const Smith = std.testing.Smith;

/// Where choices come from.
pub const Source = union(enum) {
    smith: *Smith,
    random: std.Random,

    /// A number below `n`, which must not be zero.
    pub fn index(s: Source, n: usize) usize {
        return switch (s) {
            .smith => |smith| smith.index(n),
            .random => |r| r.uintLessThan(usize, n),
        };
    }

    /// True about once in `n`.
    pub fn oneIn(s: Source, n: u64) bool {
        return switch (s) {
            .smith => |smith| smith.eosWeightedSimple(n - 1, 1),
            .random => |r| r.uintLessThan(u64, n) == 0,
        };
    }

    pub fn value(s: Source, comptime T: type) T {
        return switch (s) {
            .smith => |smith| smith.value(T),
            .random => |r| switch (@typeInfo(T)) {
                .bool => r.boolean(),
                .@"enum" => r.enumValue(T),
                else => r.int(T),
            },
        };
    }
};

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
pub fn string(s: Source, buf: []u8, pieces: []const []const u8) []u8 {
    var len: usize = 0;
    while (!s.oneIn(8)) {
        const piece = pieces[s.index(pieces.len)];
        if (len + piece.len > buf.len) break;
        @memcpy(buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buf[0..len];
}

/// Random options: every syntax field, case and `anywhere`.
pub fn options(s: Source) sweep.Options {
    const separators = [_]?u8{ '/', '/', null, '.' };
    return .{
        .syntax = .{
            .separator = separators[s.index(separators.len)],
            .globstar = s.value(sweep.Syntax.Globstar),
            .escape = s.value(bool),
            .brackets = s.value(sweep.Syntax.Brackets),
            .braces = s.value(bool),
            .unit = s.value(sweep.Syntax.Unit),
            .leading_dot = s.value(sweep.Syntax.LeadingDot),
        },
        .case = ([_]sweep.Case{ .sensitive, .ascii, .ascii_git })[s.index(3)],
        .anywhere = s.value(bool),
    };
}

/// Adapts a property over a `Source` to `std.testing.fuzz`.
pub fn fuzzed(comptime one: fn (Source) anyerror!void) fn (void, *Smith) anyerror!void {
    return struct {
        fn run(_: void, smith: *Smith) anyerror!void {
            return one(.{ .smith = smith });
        }
    }.run;
}

/// Runs `one` on `count` inputs from a seeded generator, so the properties
/// run in every `zig build test`, not only under `--fuzz`.
pub fn seeded(comptime one: fn (Source) anyerror!void, seed: u64, count: usize) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    for (0..count) |_| try one(.{ .random = prng.random() });
}
