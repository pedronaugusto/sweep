//! The automaton against its two oracles: git's own `dowild` for the git
//! dialects, and the naive backtracker for every dialect and case.
const std = @import("std");
const sweep = @import("../glob.zig");
const dowild = @import("dowild.zig");
const oracle = @import("oracle.zig");
const t3070 = @import("t3070.zig");
const gen = @import("gen.zig");
const shake = @import("shakedown");

const Answer = oracle.Answer;

fn sweepAnswer(pattern: []const u8, text: []const u8, options: sweep.Options) Answer {
    const matched = sweep.match(pattern, text, options) catch |err| switch (err) {
        error.InvalidPattern => return .invalid,
        error.PatternTooLong => unreachable,
    };
    return if (matched) .yes else .no;
}

const git_modes = [4]sweep.Options{
    .{ .syntax = .git },
    .{ .syntax = .git, .case = .ascii_git },
    .{ .syntax = .git_text },
    .{ .syntax = .git_text, .case = .ascii_git },
};

test "t3070: every row in every mode" {
    for (t3070.rows) |row| {
        for (git_modes, row.answers) |options, want| {
            const got = sweepAnswer(row.pattern, row.text, options);
            const ok = switch (want) {
                .yes => got == .yes,
                // git does not report a malformed pattern it never reaches.
                .no => got == .no or got == .invalid,
                .invalid => got == .invalid,
            };
            if (!ok) {
                std.debug.print("t3070 {s} vs {s} ({any}): want {t}, got {t}\n", .{ row.pattern, row.text, options.case, want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Holds sweep to git's `dowild` and to the oracle on one input.
fn gitOne(_: void, c: *shake.Case) anyerror!void {
    const s = c.source;
    var pattern_buf: [24]u8 = undefined;
    var text_buf: [24]u8 = undefined;
    const pattern = gen.string(s, &pattern_buf, &gen.git_pattern);
    const text = gen.string(s, &text_buf, &gen.git_text);
    for (git_modes) |options| {
        const got = sweepAnswer(pattern, text, options);
        const reference: Answer = if (dowild.match(pattern, text, .{
            .pathname = options.syntax.separator != null,
            .case_fold = options.case == .ascii_git,
        })) |m| (if (m) .yes else .no) else |err| switch (err) {
            error.InvalidPattern => .invalid,
            error.PatternTooComplex => continue,
        };
        const ok = switch (reference) {
            .yes => got == .yes,
            .no => got == .no or got == .invalid,
            .invalid => got == .invalid,
        };
        const naive = oracle.match(std.testing.allocator, pattern, text, options);
        if (!ok or naive != got) {
            std.debug.print("git: \"{f}\" vs \"{f}\" ({any}): dowild {t}, oracle {t}, sweep {t}\n", .{ std.zig.fmtString(pattern), std.zig.fmtString(text), options, reference, naive, got });
            return error.TestUnexpectedResult;
        }
    }
}

/// Holds sweep to the oracle under a random syntax, case and `anywhere`.
fn dialectOne(_: void, c: *shake.Case) anyerror!void {
    const s = c.source;
    var pattern_buf: [16]u8 = undefined;
    var text_buf: [16]u8 = undefined;
    const options = gen.options(s);
    const pattern = gen.string(s, &pattern_buf, &gen.any_pattern);
    const text = gen.string(s, &text_buf, &gen.any_text);
    const got = sweepAnswer(pattern, text, options);
    const naive = oracle.match(std.testing.allocator, pattern, text, options);
    if (naive != got) {
        std.debug.print("dialect: \"{f}\" vs \"{f}\" ({any}): oracle {t}, sweep {t}\n", .{ std.zig.fmtString(pattern), std.zig.fmtString(text), options, naive, got });
        return error.TestUnexpectedResult;
    }
}

test "git dialects equal dowild and the oracle" {
    try shake.check(std.testing.allocator, {}, gitOne, .{ .cases = 5000 });
}

test "every dialect equals the oracle" {
    try shake.check(std.testing.allocator, {}, dialectOne, .{ .cases = 8000 });
}
