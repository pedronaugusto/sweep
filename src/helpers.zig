//! Small questions about pattern text: which bytes are special, how much of
//! a pattern is a plain literal, and how to write a literal as a pattern.
const std = @import("std");
const syntax = @import("syntax.zig");

const Syntax = syntax.Syntax;

/// Whether `byte` has meaning in `sx` outside brackets: git's
/// `is_glob_special` for `Syntax.git` (`* ? [ \`), plus `{ } ,` with braces,
/// less `[` without brackets and `\` without escapes.
pub fn isSpecial(byte: u8, sx: Syntax) bool {
    return switch (byte) {
        '*', '?' => true,
        '!', '@', '+', '(', ')', '|' => sx.extglob,
        '[' => sx.brackets != .none,
        '\\' => sx.escape,
        '{', '}' => sx.braces or sx.numeric_ranges,
        ',' => sx.braces,
        else => false,
    };
}

/// Length of the leading run of `pattern` with no special byte: git's
/// `simple_length`, the part a caller can compare as plain bytes.
pub fn literalPrefix(pattern: []const u8, sx: Syntax) usize {
    for (pattern, 0..) |byte, i| if (isSpecial(byte, sx)) return i;
    return pattern.len;
}

/// Why `escape` could not write a pattern.
pub const EscapeError = errors: {
    // A block, so a linter reading the declaration sees a type.
    break :errors std.Io.Writer.Error || error{
        /// `text` holds a special byte, and the syntax has neither escapes
        /// nor brackets to quote it with.
        Unrepresentable,
    };
};

/// Writes `text` as a pattern that matches exactly `text`: special bytes
/// are `\`-escaped, or put in one-member brackets (`[*]`) when the syntax
/// has no escapes. Under a case-folding `Case` the pattern also matches the
/// other case of each letter.
pub fn escape(w: *std.Io.Writer, text: []const u8, sx: Syntax) EscapeError!void {
    if (!sx.escape and sx.brackets == .none) {
        for (text) |byte| if (isSpecial(byte, sx)) return error.Unrepresentable;
        return w.writeAll(text);
    }
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (!isSpecial(byte, sx)) continue;
        try w.writeAll(text[start..i]);
        if (sx.escape) {
            try w.writeAll(&.{ '\\', byte });
        } else {
            try w.writeAll(&.{ '[', byte, ']' });
        }
        start = i + 1;
    }
    try w.writeAll(text[start..]);
}

test isSpecial {
    try std.testing.expect(isSpecial('*', .git));
    try std.testing.expect(isSpecial('\\', .git));
    try std.testing.expect(!isSpecial('{', .git));
    try std.testing.expect(isSpecial('{', .glob));
    try std.testing.expect(!isSpecial('[', .{ .brackets = .none }));
    try std.testing.expect(!isSpecial('\\', .{ .escape = false }));
}

test literalPrefix {
    try std.testing.expectEqual(@as(usize, 4), literalPrefix("src/*.zig", .git));
    try std.testing.expectEqual(@as(usize, 3), literalPrefix("a/b", .git));
    try std.testing.expectEqual(@as(usize, 2), literalPrefix("a/{b,c}", .glob));
    try std.testing.expectEqual(@as(usize, 7), literalPrefix("a/{b,c}", .git));
}
