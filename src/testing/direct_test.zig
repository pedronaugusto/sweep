//! The direct one-shot executor against the automaton, on plain patterns.
const std = @import("std");
const syntax = @import("../syntax.zig");
const direct = @import("../direct.zig");
const Pattern = @import("../pattern.zig").Pattern;
const matchesBy = @import("../pattern.zig").matchesBy;
const room = @import("../match.zig").room;

/// One pattern as the automaton reads it, compiled on first use: an answer
/// for each subject, or that the pattern is refused.
const Reference = struct {
    pattern: []const u8,
    options: syntax.Options,
    compiled: ?Pattern = null,
    invalid: bool = false,

    const Want = enum { no, yes, invalid };

    fn want(r: *Reference, subject: []const u8) !Want {
        if (r.invalid) return .invalid;
        if (r.compiled == null) r.compiled = Pattern.compile(std.testing.allocator, r.pattern, r.options) catch |err| switch (err) {
            error.InvalidPattern => {
                r.invalid = true;
                return .invalid;
            },
            else => return err,
        };
        return if (matchesBy(&r.compiled.?, subject, .nfa)) .yes else .no;
    }

    fn deinit(r: *Reference) void {
        if (r.compiled) |*c| c.deinit();
        r.* = undefined;
    }

    /// Fails when the direct executor answers `subject` and the automaton
    /// does not give the same answer.
    fn expectSame(r: *Reference, subject: []const u8) !bool {
        const got = direct.match(r.pattern, subject, r.options, room);
        if (got == .automaton) return false;
        const want_ = try r.want(subject);
        if (@backingInt(got) != @backingInt(want_)) {
            std.debug.print("\"{f}\" vs \"{f}\" ({any}): want {t}, got {t}\n", .{ std.zig.fmtString(r.pattern), std.zig.fmtString(subject), r.options, want_, got });
            return error.TestUnexpectedResult;
        }
        return true;
    }
};

const presets = [_]syntax.Options{
    .{},
    .{ .anywhere = true },
    .{ .case = .ascii },
    .{ .case = .ascii_git, .anywhere = true },
    .{ .syntax = .git_text },
    .{ .syntax = .{ .globstar = .off } },
    .{ .syntax = .{ .globstar = .off }, .anywhere = true },
    .{ .syntax = .{ .brackets = .lenient } },
    .{ .syntax = .{ .braces = true }, .anywhere = true },
    .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } },
    .{ .syntax = .{ .separator = null, .braces = true }, .case = .ascii },
};

test "plain patterns give the automaton's answers, and refused ones go to it" {
    var prng: std.Random.DefaultPrng = .init(0xd1_4ec7);
    const random = prng.random();
    // Separators, stars and brackets most, and the bytes that hand a call
    // to the automaton or make a pattern invalid, wherever they stand.
    const alphabet = "ab/*?.A[]!-^/**ab/\\{},:";
    const subject_alphabet = "ab/.A[]!-^*?/a/b";
    var answered: usize = 0;
    var tried: usize = 0;
    var pattern_buffer: [14]u8 = undefined;
    var subject_buffer: [16]u8 = undefined;
    for (0..1500) |_| {
        const pattern = pattern_buffer[0..random.uintAtMost(usize, pattern_buffer.len)];
        for (pattern) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        for (presets) |options| {
            var reference: Reference = .{ .pattern = pattern, .options = options };
            defer reference.deinit();
            for (0..16) |_| {
                const subject = subject_buffer[0..random.uintAtMost(usize, subject_buffer.len)];
                for (subject) |*c| c.* = subject_alphabet[random.uintLessThan(usize, subject_alphabet.len)];
                tried += 1;
                if (try reference.expectSame(subject)) answered += 1;
            }
        }
    }
    // Most generated calls are plain enough for the direct executor.
    try std.testing.expect(answered > tried / 2);
}

test "deep paths with globstars and stars give the automaton's answers" {
    var prng: std.Random.DefaultPrng = .init(0xdee9);
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "b", "/", "*", "**", "**/", "/**", "?", "[ab]", "[!a]" };
    const subject_pieces = [_][]const u8{ "a", "b", "/", "ab/", "ba", "/a/" };
    var pattern_buffer: [24]u8 = undefined;
    var subject_buffer: [32]u8 = undefined;
    for (0..600) |_| {
        const pattern = build(random, &pattern_buffer, &pieces);
        for ([_]syntax.Options{ .{}, .{ .anywhere = true }, .{ .case = .ascii } }) |options| {
            var reference: Reference = .{ .pattern = pattern, .options = options };
            defer reference.deinit();
            for (0..12) |_| _ = try reference.expectSame(build(random, &subject_buffer, &subject_pieces));
        }
    }
}

fn build(random: std.Random, buffer: []u8, pieces: []const []const u8) []u8 {
    var len: usize = 0;
    while (random.uintLessThan(u8, 10) != 0) {
        const piece = pieces[random.uintLessThan(usize, pieces.len)];
        if (len + piece.len > buffer.len) break;
        @memcpy(buffer[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buffer[0..len];
}

fn expectOutcome(want: direct.Outcome, pattern: []const u8, subject: []const u8, options: syntax.Options) !void {
    try std.testing.expectEqual(want, direct.match(pattern, subject, options, room));
}

test "a pattern answered early is answered only when its unread rest is plain" {
    // The first byte decides, but the rest is refused or unread here.
    try expectOutcome(.automaton, "b[a", "a", .{});
    try expectOutcome(.automaton, "b\\", "a", .{});
    try expectOutcome(.automaton, "b{a,c}", "a", .{ .syntax = .{ .braces = true } });
    try expectOutcome(.automaton, "b}", "a", .{ .syntax = .{ .braces = true } });
    try expectOutcome(.automaton, "b[[:alpha:]]", "a", .{});
    try expectOutcome(.automaton, "b[a]", "a", .{ .case = .ascii });
    try expectOutcome(.no, "b[a]c*?", "a", .{});
    try expectOutcome(.no, "b\\", "a", .{ .syntax = .{ .escape = false } });
    try expectOutcome(.no, "b{,}", "a", .{});
    // A last-component match learns late that the pattern is a path.
    try expectOutcome(.no, "b/c", "x/a", .{ .anywhere = true });
    try expectOutcome(.yes, "x/a", "x/a", .{ .anywhere = true });
    try expectOutcome(.yes, "x/*", "x/a", .{ .anywhere = true });
    try expectOutcome(.yes, "a", "x/a", .{ .anywhere = true });
    try expectOutcome(.automaton, "b\\/", "x/a", .{ .anywhere = true });
}

test "what the automaton keeps for itself" {
    try expectOutcome(.automaton, "a\\*", "a*", .{});
    try expectOutcome(.yes, "a\\*", "a\\b", .{ .syntax = .{ .escape = false } });
    try expectOutcome(.yes, "[ab]", "b", .{});
    try expectOutcome(.yes, "[!a-z]x", "Ax", .{});
    try expectOutcome(.automaton, "[ab]", "a", .{ .case = .ascii });
    try expectOutcome(.automaton, "[[:alpha:]]", "a", .{});
    try expectOutcome(.automaton, "[a/b]", "a", .{});
    try expectOutcome(.automaton, "[ab", "a", .{});
    try expectOutcome(.automaton, "[ab]", "a", .{ .syntax = .posix });
    try expectOutcome(.yes, "[ab]", "[ab]", .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } });
    try expectOutcome(.automaton, "{a,b}", "a", .{ .syntax = .glob });
    try expectOutcome(.yes, "a,b", "a,b", .{ .syntax = .{ .braces = true } });
    try expectOutcome(.automaton, "a?", "ab", .{ .syntax = .{ .unit = .utf8 } });
    try expectOutcome(.automaton, "a*", "ab", .{ .syntax = .posix });
    try expectOutcome(.automaton, "a/**", "a/b", .{ .syntax = .{ .globstar = .anywhere } });
    try expectOutcome(.automaton, "a.b", "a.b", .{ .syntax = .{ .separator = '.' } });
}

test "globstars: zero or more whole components, and the rest from the end" {
    try expectOutcome(.yes, "**", "", .{});
    try expectOutcome(.yes, "**", "a/b", .{});
    try expectOutcome(.yes, "a/**", "a/", .{});
    try expectOutcome(.no, "a/**", "a", .{});
    try expectOutcome(.yes, "**/a", "a", .{});
    try expectOutcome(.yes, "**/a", "x/y/a", .{});
    try expectOutcome(.no, "**/a", "", .{});
    try expectOutcome(.yes, "a/**/b", "a/b", .{});
    try expectOutcome(.yes, "a/**/b", "a/x/y/b", .{});
    try expectOutcome(.yes, "a/**/", "a/", .{});
    try expectOutcome(.yes, "**/x/**/*.c", "a/x/b/c/d.c", .{});
    try expectOutcome(.no, "**/x/**/*.c", "a/x/d.h", .{});
    try expectOutcome(.yes, "a**b", "axyb", .{});
    try expectOutcome(.no, "a**b", "ax/yb", .{});
    try expectOutcome(.yes, "a/**b", "a/xb", .{});
}

test "a call refuses what it cannot hold, whoever would read the pattern" {
    const match = @import("../match.zig").match;
    const repeat = @import("shakedown").corpus.repeat;
    // Plain brackets past the call's room: refused, even where the first
    // byte decides.
    var diagnostics: syntax.Diagnostics = .{ .reason = .unclosed_brace };
    try std.testing.expectError(error.PatternTooLong, match(repeat("[a]", 65), repeat("a", 65), .{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(syntax.Diagnostics.Reason.too_long, diagnostics.reason);
    try std.testing.expectError(error.PatternTooLong, match("b" ++ repeat("[a]", 65), "a", .{}));
    try std.testing.expect(try match(repeat("[a]", 64), repeat("a", 64), .{}));
    // Units past the call's room, plain or not.
    try std.testing.expectError(error.PatternTooLong, match(repeat("a", 1025), repeat("a", 1025), .{}));
    try std.testing.expectError(error.PatternTooLong, match("b" ++ repeat("a", 1024), "a", .{}));
    try std.testing.expect(try match(repeat("a", 1024), repeat("a", 1024), .{}));
}

test "stars take the least they can before a segment, and all but the last segment's room before the last" {
    const repeat = @import("shakedown").corpus.repeat;
    // Any number of stars: each segment is found once, left to right.
    try expectOutcome(.yes, repeat("*a", 32) ++ "*b", repeat("a", 64) ++ "b", .{});
    try expectOutcome(.no, repeat("*a", 32) ++ "b", repeat("a", 4096), .{});
    try expectOutcome(.no, repeat("*a", 32) ++ "b", repeat("a", 4096), .{ .syntax = .git_text });
    try expectOutcome(.yes, "*ab*ab*", "xxabyyabzz", .{});
    try expectOutcome(.no, "*ab*ab*", "xxabyyazz", .{});
    try expectOutcome(.yes, "*a?c*[xy]", "zzabcqqx", .{});
    // A star stops at its component's end.
    try expectOutcome(.no, "*a*/b", "xa/y/b", .{});
    try expectOutcome(.yes, "*a*/b", "xay/b", .{});
    try expectOutcome(.yes, "*a*/b", "xa/y/b", .{ .syntax = .git_text });
}
