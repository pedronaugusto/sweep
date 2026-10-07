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
            const how = direct.plan(pattern, options) orelse continue;
            applied += 1;
            var compiled = try Pattern.compile(std.testing.allocator, pattern, options);
            defer compiled.deinit();
            for (0..24) |_| {
                const subject = subject_buffer[0..random.uintAtMost(usize, subject_buffer.len)];
                for (subject) |*c| c.* = subject_alphabet[random.uintLessThan(usize, subject_alphabet.len)];
                const want = matchesBy(&compiled, subject, .nfa);
                if (direct.match(pattern, subject, options, how) != want) {
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
    try std.testing.expect(direct.plan("a\\*", .{}) == null);
    try std.testing.expect(direct.plan("*a*a*a*a*a*a*a*a", .{}) != null);
    try std.testing.expect(direct.plan("*a*a*a*a*a*a*a*a*b", .{}) == null);
    try std.testing.expect(direct.plan("a\\*", .{ .syntax = .{ .escape = false } }) != null);
    try std.testing.expect(direct.plan("[ab]", .{}) != null);
    try std.testing.expect(direct.plan("[!a-z]x", .{}) != null);
    try std.testing.expect(direct.plan("[ab]", .{ .case = .ascii }) == null);
    try std.testing.expect(direct.plan("[[:alpha:]]", .{}) == null);
    try std.testing.expect(direct.plan("[a/b]", .{}) == null);
    try std.testing.expect(direct.plan("[ab", .{}) == null);
    try std.testing.expect(direct.plan("[ab]", .{ .syntax = .posix }) == null);
    try std.testing.expect(direct.plan("[ab]", .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } }) != null);
    try std.testing.expect(direct.plan("{a,b}", .{ .syntax = .glob }) == null);
    try std.testing.expect(direct.plan("a?", .{ .syntax = .{ .unit = .utf8 } }) == null);
    try std.testing.expect(direct.plan("a*", .{ .syntax = .posix }) == null);
    try std.testing.expect(direct.plan("a/**", .{ .syntax = .{ .globstar = .anywhere } }) == null);
}
