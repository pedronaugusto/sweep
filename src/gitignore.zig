//! The line grammar of `.gitignore` and `info/exclude` files: comments,
//! negation, trailing spaces, a leading `/` and a trailing `/`. Files,
//! levels, precedence and `core.excludesFile` are the caller's.
const std = @import("std");
const set = @import("set.zig");

/// One pattern line, read.
pub const Line = struct {
    /// The glob, a slice of the line: `!`, a leading `/` and a trailing
    /// `/` removed, and trailing spaces trimmed as git trims them.
    pattern: []const u8,
    /// The options git matches the glob with: its own dialect, the basename
    /// rule when the glob held no `/`, and `dir_only` for a trailing `/`.
    /// Set `entry.options.case` for `core.ignoreCase`.
    entry: set.Entry,
    /// A `!` line: a match re-includes what an earlier line excluded.
    negated: bool,
};

/// Reads one line (without its line feed; a trailing CR goes too), or null
/// for a blank line, a comment, or a line that leaves no pattern.
pub fn parseLine(line_in: []const u8) ?Line {
    var line = line_in;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (line.len == 0 or line[0] == '#') return null;
    var text = trimTrailingSpaces(line);
    if (text.len == 0) return null;
    const negated = text[0] == '!';
    if (negated) text = text[1..];
    var dir_only = false;
    if (text.len > 0 and text[text.len - 1] == '/') {
        dir_only = true;
        text = text[0 .. text.len - 1];
    }
    // A `/` anywhere but at the end anchors the glob to the file's
    // directory; with none it matches a name at any depth.
    const anchored = std.mem.findScalar(u8, text, '/') != null;
    if (text.len > 0 and text[0] == '/') text = text[1..];
    if (text.len == 0) return null;
    return .{ .pattern = text, .entry = .{ .options = .{ .syntax = .git, .anywhere = !anchored }, .dir_only = dir_only }, .negated = negated };
}

/// git's `trim_trailing_spaces`: spaces go unless a backslash escapes the
/// last one; a line ending in a lone backslash keeps everything.
fn trimTrailingSpaces(line: []const u8) []const u8 {
    var last_space: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        ' ' => {
            if (last_space == null) last_space = i;
        },
        '\\' => {
            i += 1;
            if (i >= line.len) return line;
            last_space = null;
        },
        else => last_space = null,
    };
    return line[0 .. last_space orelse line.len];
}

test parseLine {
    try std.testing.expect(parseLine("") == null);
    try std.testing.expect(parseLine("# comment") == null);
    try std.testing.expect(parseLine("   ") == null);
    try std.testing.expect(parseLine("!") == null);
    try std.testing.expect(parseLine("/") == null);
    const log = parseLine("*.log  ").?;
    try std.testing.expectEqualStrings("*.log", log.pattern);
    try std.testing.expect(log.entry.options.anywhere and !log.entry.dir_only and !log.negated);
    const kept = parseLine("!keep.log").?;
    try std.testing.expect(kept.negated);
    try std.testing.expectEqualStrings("keep.log", kept.pattern);
    const build = parseLine("/build/\r").?;
    try std.testing.expectEqualStrings("build", build.pattern);
    try std.testing.expect(build.entry.dir_only and !build.entry.options.anywhere);
    const deep = parseLine("doc/*.txt").?;
    try std.testing.expect(!deep.entry.options.anywhere);
    try std.testing.expectEqualStrings("a\\ ", parseLine("a\\ ").?.pattern);
    try std.testing.expectEqualStrings("a\\\\", parseLine("a\\\\  ").?.pattern);
    try std.testing.expectEqualStrings("\\#x", parseLine("\\#x").?.pattern);
    try std.testing.expectEqualStrings("\\!x", parseLine("\\!x").?.pattern);
    try std.testing.expectEqualStrings("a\t", parseLine("a\t").?.pattern);
    try std.testing.expectEqualStrings("x \\", parseLine("x \\").?.pattern);
}
