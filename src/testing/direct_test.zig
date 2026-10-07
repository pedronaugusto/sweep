//! The direct one-shot executor against the automaton, on plain patterns.
const std = @import("std");
const syntax = @import("../syntax.zig");
const direct = @import("../direct.zig");
const Pattern = @import("../pattern.zig").Pattern;
const matchesBy = @import("../pattern.zig").matchesBy;

test "plain patterns give the automaton's answers" {
    var prng: std.Random.DefaultPrng = .init(0xd1_4ec7);
    const random = prng.random();
    const alphabet = "ab/*?.A[]!-^";
    const subject_alphabet = "ab/.A[]!-^*?";
    const presets = [_]syntax.Options{
        .{},
        .{ .anywhere = true },
        .{ .case = .ascii },
        .{ .case = .ascii_git, .anywhere = true },
        .{ .syntax = .git_text },
        .{ .syntax = .{ .globstar = .off } },
        .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } },
    };
    var applied: usize = 0;
    var pattern_buffer: [12]u8 = undefined;
    var subject_buffer: [12]u8 = undefined;
    // Compiling is the slow part in a Debug build: each pattern meets many
    // subjects.
    for (0..1500) |_| {
        const pattern = pattern_buffer[0..random.uintAtMost(usize, pattern_buffer.len)];
        for (pattern) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        for (presets) |options| {
            if (!direct.applies(pattern, options)) continue;
            applied += 1;
            var compiled = try Pattern.compile(std.testing.allocator, pattern, options);
            defer compiled.deinit();
            for (0..24) |_| {
                const subject = subject_buffer[0..random.uintAtMost(usize, subject_buffer.len)];
                for (subject) |*c| c.* = subject_alphabet[random.uintLessThan(usize, subject_alphabet.len)];
                const want = matchesBy(&compiled, subject, .nfa);
                if (direct.match(pattern, subject, options) != want) {
                    std.debug.print("{s} vs {s} ({any}): want {}\n", .{ pattern, subject, options, want });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    // Most generated patterns are plain enough for the direct executor.
    try std.testing.expect(applied > 1500 * 7 / 2);
}

test "what the automaton keeps for itself" {
    try std.testing.expect(!direct.applies("a\\*", .{}));
    try std.testing.expect(direct.applies("*a*a*a*a*a*a*a*a", .{}));
    try std.testing.expect(!direct.applies("*a*a*a*a*a*a*a*a*b", .{}));
    try std.testing.expect(direct.applies("a\\*", .{ .syntax = .{ .escape = false } }));
    try std.testing.expect(direct.applies("[ab]", .{}));
    try std.testing.expect(direct.applies("[!a-z]x", .{}));
    try std.testing.expect(!direct.applies("[ab]", .{ .case = .ascii }));
    try std.testing.expect(!direct.applies("[[:alpha:]]", .{}));
    try std.testing.expect(!direct.applies("[a/b]", .{}));
    try std.testing.expect(!direct.applies("[ab", .{}));
    try std.testing.expect(!direct.applies("[ab]", .{ .syntax = .posix }));
    try std.testing.expect(direct.applies("[ab]", .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } }));
    try std.testing.expect(!direct.applies("{a,b}", .{ .syntax = .glob }));
    try std.testing.expect(!direct.applies("a?", .{ .syntax = .{ .unit = .utf8 } }));
    try std.testing.expect(!direct.applies("a*", .{ .syntax = .posix }));
    try std.testing.expect(!direct.applies("a/**", .{ .syntax = .{ .globstar = .anywhere } }));
}
