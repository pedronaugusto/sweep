//! The reference: git's `dowild` from `wildmatch.c`, as a backtracker over
//! bytes. Test-only and never exported. The differential tests hold sweep's
//! automaton to it answer for answer.
//!
//! It came from relic's port, where it was checked against git 2.55. It
//! reports a malformed bracket only when matching reaches it, as git does;
//! `PatternTooComplex` is its own stack guard, not git's.
const std = @import("std");

/// Flags that change what a pattern means.
pub const Options = struct {
    /// WM_PATHNAME: `*` and `?` do not match `/`, and `**` is only special
    /// as a whole path component.
    pathname: bool = true,
    /// WM_CASEFOLD: compare ASCII letters case-insensitively.
    case_fold: bool = false,
};

/// Errors from the glob matcher.
pub const Error = error{
    /// A `[` with no `]`, or a bracket expression naming an unknown class.
    InvalidPattern,
    /// The pattern nested wildcards deeper than the matcher will recurse.
    PatternTooComplex,
};

/// Whether `pattern` matches the whole of `text`.
///
/// A malformed bracket expression is only reported when matching reaches it;
/// `match("x[abc", "y", .{})` is a plain `false` because the `x` already
/// failed, which is how git behaves too.
pub fn match(pattern: []const u8, text: []const u8, options: Options) Error!bool {
    return try dowild(pattern, 0, text, 0, options, 0) == .match;
}

/// What a match attempt says, as git's `dowild` says it. The two aborts are
/// what keep backtracking linear: a failure no later placement of an outer
/// star can mend says so, and the outer stars stop trying.
const Outcome = enum {
    match,
    no_match,
    /// No placement of any star can match: the text ran out, or a literal
    /// after a star is nowhere in the rest of it.
    abort_all,
    /// No placement of a star short of a `**` can match: only a `**` that
    /// may cross a `/` is worth moving.
    abort_to_starstar,
};

/// Every star tried is one frame, so a pattern of a few hundred stars is as
/// deep as this goes; past it the pattern is refused rather than run off the
/// stack.
const max_depth = 1024;

/// git's `dowild` from `wildmatch.c`, over bytes: a star tries each place
/// the rest of the pattern could start, and gives up on the first abort.
fn dowild(
    pattern: []const u8,
    pattern_start: usize,
    text: []const u8,
    text_start: usize,
    options: Options,
    depth: u32,
) Error!Outcome {
    if (depth > max_depth) return error.PatternTooComplex;
    var p = pattern_start;
    var t = text_start;
    while (p < pattern.len) {
        if (pattern[p] != '*') {
            if (t >= text.len) return .abort_all;
            const item = try matchItem(pattern, p, text[t], options);
            if (!item.matched) return .no_match;
            p = item.next;
            t += 1;
            continue;
        }

        // A run of stars, and how far it may reach.
        var q = p + 1;
        var match_slash = !options.pathname;
        if (q < pattern.len and pattern[q] == '*') {
            while (q < pattern.len and pattern[q] == '*') q += 1;
            const starts_component = p == 0 or pattern[p - 1] == '/';
            const ends_component = q == pattern.len or pattern[q] == '/' or
                (pattern[q] == '\\' and q + 1 < pattern.len and pattern[q + 1] == '/');
            if (!options.pathname) {
                match_slash = true;
            } else if (starts_component and ends_component) {
                // `**/` may match nothing at all, slash included, which is
                // what lets `a/**/b` match `a/b`.
                if (q < pattern.len and pattern[q] == '/') {
                    if (try dowild(pattern, q + 1, text, t, options, depth + 1) == .match) return .match;
                }
                match_slash = true;
            }
        }
        p = q;

        if (p == pattern.len) {
            // A trailing `**` matches everything; a trailing `*` only what
            // has no slash left.
            if (!match_slash and std.mem.findScalarPos(u8, text, t, '/') != null) return .abort_to_starstar;
            return .match;
        }
        if (!match_slash and pattern[p] == '/') {
            // One star and a slash: the star takes the rest of this
            // component, and the slashes meet.
            const slash = std.mem.findScalarPos(u8, text, t, '/') orelse return .abort_all;
            t = slash + 1;
            p += 1;
            continue;
        }
        while (t < text.len) {
            // A literal after the star: the star takes everything before
            // its next appearance, and none appearing is the end of it.
            if (!isGlobSpecial(pattern[p])) {
                const want = if (options.case_fold) fold(pattern[p]) else pattern[p];
                while (t < text.len and (match_slash or text[t] != '/')) : (t += 1) {
                    const have = if (options.case_fold) fold(text[t]) else text[t];
                    if (have == want) break;
                }
                if (t >= text.len or (if (options.case_fold) fold(text[t]) else text[t]) != want) {
                    return if (match_slash) .abort_all else .abort_to_starstar;
                }
            }
            const matched = try dowild(pattern, p, text, t, options, depth + 1);
            if (matched != .no_match) {
                if (!match_slash or matched != .abort_to_starstar) return matched;
            } else if (!match_slash and text[t] == '/') return .abort_to_starstar;
            t += 1;
        }
        return .abort_all;
    }
    return if (t == text.len) .match else .no_match;
}

/// git's `is_glob_special`: the bytes a star cannot skip ahead to.
fn isGlobSpecial(c: u8) bool {
    return c == '*' or c == '?' or c == '[' or c == '\\';
}

const Item = struct {
    matched: bool,
    /// Index just past the pattern item, whatever its length.
    next: usize,
};

/// Matches the single pattern item at `pi` against one text byte.
fn matchItem(pattern: []const u8, pi: usize, raw: u8, options: Options) Error!Item {
    const text_byte = if (options.case_fold) fold(raw) else raw;
    switch (pattern[pi]) {
        '?' => return .{ .matched = !(options.pathname and raw == '/'), .next = pi + 1 },
        '[' => return matchBracket(pattern, pi, text_byte, options),
        '\\' => {
            // The escaped pattern byte is compared raw against the folded
            // text byte, exactly as git does it, so under WM_CASEFOLD `\b`
            // matches `B` while `\A` does not match `a`.
            //
            // A trailing lone `\` matches nothing at all: git reads the byte
            // past the end of the pattern as NUL, so an ignore line written
            // `a\` does not match a file named `a\` while `a\\` does.
            // Confirmed against git 2.55 rather than assumed.
            if (pi + 1 >= pattern.len) return .{ .matched = false, .next = pi + 1 };
            return .{ .matched = text_byte == pattern[pi + 1], .next = pi + 2 };
        },
        else => {
            const pattern_byte = if (options.case_fold) fold(pattern[pi]) else pattern[pi];
            return .{ .matched = text_byte == pattern_byte, .next = pi + 1 };
        },
    }
}

/// Matches a bracket expression starting at the `[` in `pattern[pi]`.
///
/// `text_byte` arrives already case-folded, the same way git folds the text
/// byte once before it looks at the pattern. Range ends are compared unfolded
/// against it, with a second try at the upper-case text byte, which is why
/// `[A-Z]` matches `a` under case folding but `[A]` does not.
fn matchBracket(pattern: []const u8, pi: usize, text_byte: u8, options: Options) Error!Item {
    var p = pi + 1;
    if (p >= pattern.len) return error.InvalidPattern;

    var negated = false;
    if (pattern[p] == '!' or pattern[p] == '^') {
        negated = true;
        p += 1;
    }

    var matched = false;
    // Zero means "no byte that could open a range", which is how git spells
    // it; a range end and a character class both reset it.
    var prev: u8 = 0;

    while (true) {
        if (p >= pattern.len) return error.InvalidPattern;
        var current = pattern[p];

        if (current == '\\') {
            p += 1;
            if (p >= pattern.len) return error.InvalidPattern;
            current = pattern[p];
            if (text_byte == current) matched = true;
        } else if (current == '-' and prev != 0 and p + 1 < pattern.len and pattern[p + 1] != ']') {
            p += 1;
            var high = pattern[p];
            if (high == '\\') {
                p += 1;
                if (p >= pattern.len) return error.InvalidPattern;
                high = pattern[p];
            }
            if (text_byte >= prev and text_byte <= high) {
                matched = true;
            } else if (options.case_fold and isLower(text_byte)) {
                const upper = text_byte - ('a' - 'A');
                if (upper >= prev and upper <= high) matched = true;
            }
            current = 0;
        } else if (current == '[' and p + 1 < pattern.len and pattern[p + 1] == ':') {
            const name_start = p + 2;
            var close = name_start;
            while (close < pattern.len and pattern[close] != ']') close += 1;
            if (close >= pattern.len) return error.InvalidPattern;
            if (close < name_start + 1 or pattern[close - 1] != ':') {
                // No `:]`, so the `[` is an ordinary member and scanning
                // resumes at the `:` right after it.
                if (text_byte == '[') matched = true;
            } else {
                if (try matchClass(pattern[name_start .. close - 1], text_byte, options)) matched = true;
                p = close;
                current = 0;
            }
        } else if (text_byte == current) {
            matched = true;
        }

        prev = current;
        p += 1;
        if (p < pattern.len and pattern[p] == ']') break;
    }

    // A bracket never matches a separator under WM_PATHNAME, not even `[/]`.
    const hit = (matched != negated) and !(options.pathname and text_byte == '/');
    return .{ .matched = hit, .next = p + 1 };
}

/// Whether `text_byte` belongs to the POSIX class `name`.
///
/// The classes are ASCII only: git builds them from its own table, so a byte
/// above 0x7f is in no class regardless of locale.
fn matchClass(name: []const u8, text_byte: u8, options: Options) Error!bool {
    const c = text_byte;
    if (std.mem.eql(u8, name, "alnum")) return isAlpha(c) or isDigit(c);
    if (std.mem.eql(u8, name, "alpha")) return isAlpha(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return c < 0x20 or c == 0x7f;
    if (std.mem.eql(u8, name, "digit")) return isDigit(c);
    if (std.mem.eql(u8, name, "graph")) return c > 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "lower")) return isLower(c);
    if (std.mem.eql(u8, name, "print")) return c >= 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "punct")) return c > 0x20 and c < 0x7f and !isAlpha(c) and !isDigit(c);
    if (std.mem.eql(u8, name, "space")) return c == ' ' or (c >= '\t' and c <= '\r');
    if (std.mem.eql(u8, name, "upper")) return isUpper(c) or (options.case_fold and isLower(c));
    if (std.mem.eql(u8, name, "xdigit")) return isDigit(c) or (c | 0x20) >= 'a' and (c | 0x20) <= 'f';
    return error.InvalidPattern;
}

fn fold(c: u8) u8 {
    return if (isUpper(c)) c + ('a' - 'A') else c;
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isAlpha(c: u8) bool {
    return isUpper(c) or isLower(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
