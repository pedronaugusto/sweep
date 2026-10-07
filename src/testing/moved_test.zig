//! The glob tests of the packages sweep replaces, kept as they move in.
//! Rows whose answer changed carry the reason.
const std = @import("std");
const sweep = @import("../sweep.zig");

/// gantry's path rules: git's dialect with the basename rule.
fn path(pattern: []const u8, subject: []const u8) bool {
    return sweep.match(pattern, subject, .{ .anywhere = true }) catch false;
}

/// gantry's token rules: every byte but `*` and `?` matches itself.
fn token(pattern: []const u8, text: []const u8) bool {
    return sweep.match(pattern, text, .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } }) catch false;
}

test "gantry: path globs are component-aware and double-star covers zero directories" {
    const cases = [_]struct { pattern: []const u8, path: []const u8, want: bool }{
        .{ .pattern = "src/**/*.zig", .path = "src/main.zig", .want = true },
        .{ .pattern = "src/**/*.zig", .path = "src/deep/main.zig", .want = true },
        .{ .pattern = "src/*.zig", .path = "src/deep/main.zig", .want = false },
        .{ .pattern = "**/main.zig", .path = "main.zig", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/b", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/c", .want = false },
        .{ .pattern = "a?c*", .path = "dir/abcde", .want = true },
        .{ .pattern = "src/*", .path = "src/deep/x", .want = false },
        // Flipped (owner decision 3): `a/**` needs the separator, as in git.
        .{ .pattern = "src/**", .path = "src", .want = false },
        .{ .pattern = "src/**", .path = "src/", .want = true },
        .{ .pattern = "src/**", .path = "src2/x", .want = false },
        .{ .pattern = "**", .path = "", .want = true },
        .{ .pattern = "*.zig", .path = "main.ZIG", .want = false },
        .{ .pattern = "a*b?d", .path = "a12b3d", .want = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, path(case.pattern, case.path));
}

test "gantry: ** is a whole component and a slashless pattern the base name" {
    // Flipped (owner decision 3): `a/**` no longer matches `a`.
    try std.testing.expect(!path("a/**", "a"));
    try std.testing.expect(path("a/**", "a/b/c"));
    try std.testing.expect(path("a/**/c", "a/c"));
    try std.testing.expect(!path("a**/c", "ax/y/c"));
    try std.testing.expect(path("a**/c", "ax/c"));
    try std.testing.expect(path("*.zig", "src/x/a.zig"));
    try std.testing.expect(!path("src/*.zig", "src/x/a.zig"));
}

test "gantry: token patterns, star spans any bytes and question mark one" {
    const cases = [_]struct { pattern: []const u8, text: []const u8, want: bool }{
        .{ .pattern = "kill", .text = "kill", .want = true },
        .{ .pattern = "kill", .text = "killpg", .want = false },
        .{ .pattern = "Create*W", .text = "CreateFileW", .want = true },
        .{ .pattern = "*.git*", .text = "a/.git/config", .want = true },
        .{ .pattern = "*.git", .text = ".gitignore", .want = false },
        .{ .pattern = "\x1b?", .text = "\x1b]", .want = true },
        // tycho's layer token: brackets stay literal in token rules.
        .{ .pattern = "*\x1b[*", .text = "say \x1b[0m", .want = true },
        .{ .pattern = "a\\b", .text = "a\\b", .want = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, token(case.pattern, case.text));
}
