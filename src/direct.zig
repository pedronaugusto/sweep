//! The one-shot executor for plain patterns: literal bytes, `?`, `*` and
//! `**`, read straight from the pattern with no parse and no automaton.
//!
//! A bracket of bytes and ranges is read where it stands, as git reads it;
//! a named class, an escape or a separator inside one is the automaton's.
//!
//! A component is matched with one retry point, the last `*`; components
//! are matched with one more, the last `**` standing as a whole component.
//! A later star covers everything an earlier one could still take, so one
//! retry per level finds a match when there is one, in O(n·m) steps as the
//! automaton takes. The automaton answers everything else.
const std = @import("std");
const syntax = @import("syntax.zig");

/// The most runs of `*` a pattern this executor takes may hold.
const max_star_runs = 8;

/// Whether `match` can take `pattern` under `options`: bytes, wildcards
/// that never look at a leading dot, no escape or brace in the pattern,
/// brackets only of bytes and ranges with case kept, and `/` or no
/// separator.
pub inline fn applies(pattern: []const u8, options: syntax.Options) bool {
    const sx = options.syntax;
    if (sx.unit != .byte or sx.leading_dot != .ordinary or sx.globstar == .anywhere) return false;
    if (sx.separator) |separator| if (separator != '/') return false;
    // A dialect with no escape, bracket or brace has nothing to look for.
    if (!sx.escape and sx.brackets == .none and !sx.braces) return true;
    // Each run of stars is a retry the automaton runs in parallel words and
    // this executor one at a time: past a few, as in adversarial shapes, the
    // automaton is faster.
    var stars: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) switch (pattern[i]) {
        '*' => if (i == 0 or pattern[i - 1] != '*') {
            stars += 1;
            if (stars > max_star_runs) return false;
        },
        '\\' => if (sx.escape) return false,
        '[' => if (sx.brackets != .none) {
            if (sx.brackets != .strict or options.case != .sensitive) return false;
            i = (bracketEnd(pattern, i) orelse return false) - 1;
        },
        '{', '}', ',' => if (sx.braces) return false,
        else => {},
    };
    return true;
}

/// Where the bracket opening at `open` ends (after its `]`), read by git's
/// procedure: an optional `!` or `^`, then members, the first taken whatever
/// it is, up to a `]`. Null for one `applies` leaves to the automaton: a
/// named class, an escape or a separator in it, or no `]`.
fn bracketEnd(pattern: []const u8, open: usize) ?usize {
    var at = open + 1;
    if (at < pattern.len and (pattern[at] == '!' or pattern[at] == '^')) at += 1;
    while (true) : (at += 1) {
        if (at >= pattern.len) return null;
        switch (pattern[at]) {
            '\\', '/' => return null,
            '[' => if (at + 1 < pattern.len and pattern[at + 1] == ':') return null,
            else => {},
        }
        if (at + 1 < pattern.len and pattern[at + 1] == ']') return at + 2;
    }
}

/// Whether byte `c` is a member of the bracket `pattern[open..end]`, which
/// `bracketEnd` read.
fn inBracket(pattern: []const u8, open: usize, end: usize, c: u8) bool {
    var at = open + 1;
    const negated = pattern[at] == '!' or pattern[at] == '^';
    if (negated) at += 1;
    // git's `prev`: the member a `-` would open a range from, 0 for none.
    var prev: u8 = 0;
    var found = false;
    while (at < end - 1) : (at += 1) {
        const m = pattern[at];
        if (m == '-' and prev != 0 and at + 1 < end - 1) {
            at += 1;
            if (prev <= c and c <= pattern[at]) found = true;
            prev = 0;
        } else {
            if (m == c) found = true;
            prev = m;
        }
    }
    return found != negated;
}

/// Whether `pattern`, which `applies` takes, matches all of `subject`.
pub noinline fn match(pattern: []const u8, subject: []const u8, options: syntax.Options) bool {
    return if (options.case == .sensitive) matchAs(false, pattern, subject, options) else matchAs(true, pattern, subject, options);
}

/// `match` with the case rule fixed, so the compare in the inner loop is one
/// instruction for the common case.
fn matchAs(comptime fold: bool, pattern: []const u8, subject: []const u8, options: syntax.Options) bool {
    const brackets = options.syntax.brackets != .none;
    if (options.syntax.separator == null) return component(fold, brackets, pattern, subject);
    const globstar = options.syntax.globstar == .component;
    // `anywhere` reads a pattern holding no separator as `**/` before it,
    // and a leading `**/` before one component means the same: only the
    // subject's last component can match.
    const last: ?[]const u8 = if (std.mem.findScalar(u8, pattern, '/')) |slash|
        (if (globstar and isGlobstar(pattern[0..slash]) and std.mem.findScalarPos(u8, pattern, slash + 1, '/') == null) pattern[slash + 1 ..] else null)
    else if (options.anywhere) pattern else null;
    if (last) |piece| {
        const base = if (std.mem.findScalarLast(u8, subject, '/')) |slash| slash + 1 else 0;
        return component(fold, brackets, piece, subject[base..]);
    }
    return components(fold, pattern, subject, globstar, brackets);
}

/// One component of a string, `text[start..stop]`, and whether one follows.
const Cursor = struct {
    text: []const u8,
    start: usize = 0,
    stop: usize,
    /// Every component has been consumed.
    done: bool = false,

    fn init(text: []const u8) Cursor {
        return .{ .text = text, .stop = std.mem.findScalar(u8, text, '/') orelse text.len };
    }
    fn current(c: Cursor) []const u8 {
        return c.text[c.start..c.stop];
    }
    fn last(c: Cursor) bool {
        return c.stop == c.text.len;
    }
    fn advance(c: *Cursor) void {
        if (c.stop == c.text.len) {
            c.done = true;
            return;
        }
        c.start = c.stop + 1;
        c.stop = std.mem.findScalarPos(u8, c.text, c.start, '/') orelse c.text.len;
    }
    /// Moves to the `count`th component from the end; false when fewer are
    /// left.
    fn fromEnd(c: *Cursor, count: usize) bool {
        var end = c.text.len;
        var n: usize = 1;
        while (true) : (n += 1) {
            const begin = if (std.mem.findScalarLast(u8, c.text[0..end], '/')) |slash| slash + 1 else 0;
            if (begin < c.start) return false;
            if (n == count) {
                c.start = begin;
                c.stop = std.mem.findScalarPos(u8, c.text, begin, '/') orelse c.text.len;
                return true;
            }
            if (begin == c.start) return false;
            end = begin - 1;
        }
    }
};

fn isGlobstar(piece: []const u8) bool {
    return piece.len >= 2 and std.mem.countScalar(u8, piece, '*') == piece.len;
}

fn components(comptime fold: bool, pattern: []const u8, subject: []const u8, globstar: bool, brackets: bool) bool {
    var p: Cursor = .init(pattern);
    var s: Cursor = .init(subject);
    // Where the last whole-component `**` resumes: the pattern after it,
    // and the subject component it would take next.
    var retry: ?struct { p: Cursor, s: Cursor } = null;
    while (true) {
        if (!p.done) {
            const piece = p.current();
            if (globstar and isGlobstar(piece)) {
                // A trailing `**` takes whatever follows its separator, and
                // the separator needs a component after it.
                if (p.last()) return !s.done;
                p.advance();
                if (s.done) return false;
                // With no `**` after this one, the rest has a fixed number
                // of components, and they are the subject's last ones.
                if (tail(p, globstar)) |count| {
                    if (!s.fromEnd(count)) return false;
                    retry = null;
                } else retry = .{ .p = p, .s = s };
                continue;
            }
            if (!s.done and component(fold, brackets, piece, s.current())) {
                p.advance();
                s.advance();
                continue;
            }
        } else if (s.done) return true;
        // The last `**` takes one more component and the rest is tried again.
        const r = &(retry orelse return false);
        r.s.advance();
        if (r.s.done) return false;
        p = r.p;
        s = r.s;
    }
}

/// How many components remain from `p` on, or null when a `**` is among
/// them.
fn tail(p: Cursor, globstar: bool) ?usize {
    var c = p;
    var count: usize = 0;
    while (!c.done) : (c.advance()) {
        if (globstar and isGlobstar(c.current())) return null;
        count += 1;
    }
    return count;
}

/// Whether a pattern with no separator in it matches all of `subject`: `*`
/// takes any run, `?` one byte, a bracket one of its members when
/// `brackets`, every other byte itself.
fn component(comptime fold: bool, brackets: bool, pattern: []const u8, subject: []const u8) bool {
    const none = std.math.maxInt(usize);
    var i: usize = 0;
    var j: usize = 0;
    // The pattern after the last `*`, and where in the subject it resumes.
    var star: usize = none;
    var resume_at: usize = 0;
    while (j < subject.len) {
        if (i < pattern.len) {
            const c = pattern[i];
            if (c == '[' and brackets) {
                const end = bracketEnd(pattern, i).?;
                if (inBracket(pattern, i, end, subject[j])) {
                    i = end;
                    j += 1;
                    continue;
                }
            } else if (c == '*') {
                i += 1;
                star = i;
                resume_at = j;
                continue;
            } else if (c == '?' or same(fold, c, subject[j])) {
                i += 1;
                j += 1;
                continue;
            }
        }
        if (star == none) return false;
        resume_at += 1;
        j = resume_at;
        i = star;
    }
    while (i < pattern.len and pattern[i] == '*') i += 1;
    return i == pattern.len;
}

fn same(comptime fold: bool, a: u8, b: u8) bool {
    return if (fold) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

/// Whether `options` read every byte but `*` and `?` as itself, with no
/// separator and no case rule: a token dialect, where `text` decides alone.
pub inline fn literalText(options: syntax.Options) bool {
    const sx = options.syntax;
    return sx.separator == null and !sx.escape and sx.brackets == .none and !sx.braces and sx.unit == .byte and
        sx.leading_dot == .ordinary and options.case == .sensitive;
}

/// `match` for options `literalText` takes.
pub fn literal(pattern: []const u8, subject: []const u8) bool {
    return component(false, false, pattern, subject);
}
