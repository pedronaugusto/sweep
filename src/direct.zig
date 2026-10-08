//! The one-shot executor for plain patterns: literal bytes, `?`, `*`, `**`
//! and brackets of bytes and ranges, read straight from the pattern as the
//! subject is, in one pass with no parse and no automaton, the way git's
//! `dowild` reads them, with no backtracking.
//!
//! Stars split a component into segments of units one byte wide. A star
//! before the last segment takes exactly what that segment leaves of the
//! component; a star before any other takes the least it can, up to the
//! segment's first place, since the next star covers whatever a later place
//! would leave. So a component is read once. Components are matched with
//! one retry point, the last `**` standing as a whole component, which a
//! later one covers in the same way; after the last, the rest of the
//! pattern is the subject's last components, tried once.
//!
//! The pattern is read only as far as the answer needs. A byte this
//! executor does not read (an escape, a brace, a named class) hands the
//! whole call to the automaton, and so does one in the unread rest of a
//! pattern answered early, since it may make the pattern invalid.
const std = @import("std");
const syntax = @import("syntax.zig");

/// The answer, or who gives it.
pub const Outcome = enum {
    no,
    yes,
    /// The pattern holds something only the automaton reads.
    automaton,
};

/// What each byte may mean, before a dialect says whether it does.
const Role = struct {
    const star: u8 = 1 << 0;
    const any: u8 = 1 << 1;
    const separator: u8 = 1 << 2;
    const bracket: u8 = 1 << 3;
    const escape: u8 = 1 << 4;
    const brace: u8 = 1 << 5;
    /// Not a byte's role: `**` standing as a component is a globstar.
    const globstar: u8 = 1 << 6;
    /// Not a byte's role: a bracket is read here, not by the automaton.
    const read_brackets: u8 = 1 << 7;
    /// The roles this executor hands to the automaton wherever they stand.
    const foreign: u8 = escape | brace;

    const of: [256]u8 = table: {
        var t: [256]u8 = @splat(0);
        t['*'] = star;
        t['?'] = any;
        t['/'] = separator;
        t['['] = bracket;
        t['\\'] = escape;
        t['{'] = brace;
        t['}'] = brace;
        break :table t;
    };
};

/// What the automaton beside this executor holds. A pattern past it is
/// handed on, to be refused there, so that whether a call refuses a
/// pattern never depends on who would read it.
pub const Room = struct {
    units: usize,
    brackets: usize,
};

/// Whether `pattern` matches all of `subject` under `options`, or that the
/// automaton must say: it takes bytes as units, wildcards that never look at
/// a leading dot, `/` or no separator, and brackets with case kept, in a
/// pattern that fits `room`.
pub inline fn match(pattern: []const u8, subject: []const u8, options: syntax.Options, room: Room) Outcome {
    const sx = options.syntax;
    if (sx.alternate_separator != null or options.normalization == .nfc or options.case == .unicode or sx.root_slash or sx.basename or sx.bracket_separator_literal or sx.extglob or sx.numeric_ranges or sx.unit != .byte or sx.leading_dot != .ordinary or sx.globstar == .anywhere) return .automaton;
    // A byte is a unit here.
    if (pattern.len > room.units) return .automaton;
    var roles: u8 = Role.star | Role.any;
    if (sx.escape) roles |= Role.escape;
    if (sx.braces) roles |= Role.brace;
    if (sx.brackets != .none) roles |= Role.bracket;
    if (sx.brackets == .strict and options.case == .sensitive) roles |= Role.read_brackets;
    // The shortest bracket is three bytes: only a longer pattern can hold
    // more than the room.
    if (roles & Role.bracket != 0 and pattern.len > 3 * room.brackets and moreBrackets(pattern, roles, room.brackets)) return .automaton;
    const fold = options.case != .sensitive;
    // Alphabetic bytes are literals in every supported direct dialect.
    // Most anchored paths fail here, before pathname setup or a role lookup.
    var start: usize = 0;
    if (!options.anywhere and pattern.len > 0 and pattern[0] >= 'a' and pattern[0] <= 'z') {
        if (subject.len == 0 or (if (fold) !same(true, pattern[0], subject[0]) else pattern[0] != subject[0])) {
            if (Needles.of(roles)) |needles| if (needles.anyIn(pattern[1..])) return settleRest(pattern[1..], roles);
            return .no;
        }
        start = 1;
        if (!fold and roles & Needles.checked == Role.bracket | Role.escape and pattern.len >= 8) {
            const word = std.mem.readInt(u64, pattern[0..8], .little);
            if (!Needles.prefix.inWord(word)) {
                if (subject.len < 8 or word != std.mem.readInt(u64, subject[0..8], .little)) return settle(pattern, 8, roles);
                start = 8;
            }
        }
    }
    if (sx.separator) |separator| {
        if (separator != '/') return .automaton;
        roles |= Role.separator;
        if (sx.globstar == .component) roles |= Role.globstar;
        return if (fold) path(true, pattern, subject, roles, options.anywhere, start) else path(false, pattern, subject, roles, options.anywhere, start);
    }
    return if (fold) read(true, false, pattern, subject, roles) else read(false, false, pattern, subject, roles);
}

/// Whether the direct executor can decide this complete, validated pattern.
pub noinline fn supports(pattern: []const u8, options: syntax.Options, room: Room) bool {
    if (options.syntax.separator) |separator| if (separator != '/') return false;
    var subject: []const u8 = "";
    _ = &subject;
    return match(pattern, subject, options, room) != .automaton;
}

/// Validated plain-pattern execution. Compilation has checked the whole
/// pattern, so a mismatch needs no scan for malformed unread syntax.
pub const Compiled = struct {
    roles: u8,
    fold: bool,
    separated: bool,
    anywhere: bool,

    pub fn init(pattern: []const u8, options: syntax.Options, brackets: usize, room: Room) ?Compiled {
        if (!supports(pattern, options, room)) return null;
        var roles: u8 = Role.star | Role.any;
        if (brackets > 0 and options.syntax.brackets != .none) roles |= Role.bracket | Role.read_brackets;
        if (options.syntax.separator != null) roles |= Role.separator;
        if (options.syntax.globstar == .component) roles |= Role.globstar;
        return .{ .roles = roles, .fold = options.case != .sensitive, .separated = options.syntax.separator != null, .anywhere = options.anywhere };
    }

    pub fn matches(c: Compiled, pattern: []const u8, subject: []const u8) bool {
        return (if (c.separated)
            (if (c.fold) path(true, pattern, subject, c.roles, c.anywhere, 0) else path(false, pattern, subject, c.roles, c.anywhere, 0))
        else
            (if (c.fold) read(true, false, pattern, subject, c.roles) else read(false, false, pattern, subject, c.roles))) == .yes;
    }
};

/// A pattern of paths. One with no separator matches the last component
/// when `anywhere` is set, and so does one after a leading `**/`.
fn path(comptime fold: bool, pattern: []const u8, subject: []const u8, roles: u8, anywhere: bool, start: usize) Outcome {
    if (start == 0 and roles & Role.globstar != 0 and std.mem.startsWith(u8, pattern, "**/")) {
        if (std.mem.findScalarPos(u8, pattern, 3, '/') == null) return last(fold, pattern[3..], subject, roles);
    } else if (anywhere and std.mem.findScalar(u8, pattern, '/') == null) {
        return last(fold, pattern, subject, roles);
    }
    return readFrom(fold, true, pattern, subject, roles, start);
}

/// `pattern`, which holds no separator, against the last component of
/// `subject`.
fn last(comptime fold: bool, pattern: []const u8, subject: []const u8, roles: u8) Outcome {
    // Stars and then one segment need only the subject's end: the stars
    // take the rest of the component, and the segment's units, which never
    // match a separator, show that it is long enough.
    var stars: usize = 0;
    while (stars < pattern.len and pattern[stars] == '*') stars += 1;
    if (stars > 0) if (Segment.read(true, pattern, stars, roles)) |tail| if (!tail.star) {
        if (subject.len < tail.units) return .no;
        return read(fold, true, pattern[stars..], subject[subject.len - tail.units ..], roles);
    };
    // Otherwise the component is read as text: it holds no separator for
    // a wildcard to meet.
    const start = if (Slashes.last(subject, 0, subject.len)) |slash| slash + 1 else 0;
    return read(fold, false, pattern, subject[start..], roles & ~Role.separator);
}

/// Reads the literal bytes a pattern starts with, where most answers are
/// found, with nothing else live; the reader takes over at the first byte
/// with a role. With `separated` false it reads text: wildcards take any
/// byte.
inline fn read(comptime fold: bool, comptime separated: bool, pattern: []const u8, subject: []const u8, roles: u8) Outcome {
    return readFrom(fold, separated, pattern, subject, roles, 0);
}

inline fn readFrom(comptime fold: bool, comptime separated: bool, pattern: []const u8, subject: []const u8, roles: u8, start: usize) Outcome {
    var i = start;
    var at = start;
    while (i < pattern.len) {
        const c = pattern[i];
        // A whole-component star needs only its next separator. Consume it
        // here without setting up segment searches or globstar retry state.
        if (separated and c == '*' and i + 1 < pattern.len and pattern[i + 1] == '/') {
            const slash = Slashes.first(subject, at) orelse return settle(pattern, i + 2, roles);
            i += 2;
            at = slash + 1;
            continue;
        }
        if (Role.of[c] & (roles & ~Role.separator) != 0) return run(fold, separated, pattern, subject, roles, i, at);
        if (at == subject.len or !same(fold, c, subject[at])) return settle(pattern, i, roles);
        i += 1;
        at += 1;
    }
    return if (at == subject.len) .yes else .no;
}

/// No retry point.
const none = std.math.maxInt(usize);

/// The reader, from the supplied pattern and subject offsets.
noinline fn run(comptime fold: bool, comptime separated: bool, pattern: []const u8, subject: []const u8, roles: u8, start: usize, subject_start: usize) Outcome {
    var r: Reader(fold, separated) = .{ .pattern = pattern, .subject = subject, .roles = roles, .p = start, .s = subject_start, .seen = start };
    while (true) {
        const step: Step = step: {
            if (r.p == pattern.len) break :step if (r.s == subject.len) .{ .done = .yes } else .fail;
            const c = pattern[r.p];
            const role = Role.of[c] & roles;
            if (role != 0) break :step r.special(role);
            // A literal byte: most of a pattern.
            if (r.s == subject.len or !same(fold, c, subject[r.s])) break :step .fail;
            r.p += 1;
            r.s += 1;
            continue;
        };
        switch (step) {
            .next => {},
            .done => |outcome| return outcome,
            .fail => {
                r.seen = @max(r.seen, r.p);
                if (!r.retry()) return settle(pattern, r.seen, roles);
            },
        }
    }
}

/// What one step of the reading leads to.
const Step = union(enum) {
    /// The pattern and subject moved on together.
    next,
    /// They cannot from here.
    fail,
    done: Outcome,
};

/// One call's reading: where the pattern and the subject stand, and the
/// retry point.
fn Reader(comptime fold: bool, comptime separated: bool) type {
    return struct {
        pattern: []const u8,
        subject: []const u8,
        roles: u8,
        p: usize,
        s: usize,
        /// The pattern after the last `**/`, and the separators after the
        /// subject component it leaves to the rest.
        deep_p: usize = none,
        deep: Slashes = undefined,
        /// The pattern before `seen` has been read and is this executor's.
        seen: usize,

        const Self = @This();

        /// Reads the unit at `p`, which has `role` in this dialect.
        inline fn special(r: *Self, role: u8) Step {
            if (role == Role.star) return r.stars();
            if (role & Role.foreign != 0 or (role == Role.bracket and r.roles & Role.read_brackets == 0)) return .{ .done = .automaton };
            // `?`, a separator and a bracket each take one byte.
            if (r.s == r.subject.len) return .fail;
            const b = r.subject[r.s];
            var next = r.p + 1;
            switch (role) {
                Role.any => if (separated and b == '/') return .fail,
                Role.separator => if (b != '/') return .fail,
                Role.bracket => {
                    next = bracketEnd(r.pattern, r.p) orelse return .{ .done = .automaton };
                    r.seen = @max(r.seen, next);
                    if ((separated and b == '/') or !inBracket(r.pattern, r.p, next, b)) return .fail;
                },
                else => unreachable,
            }
            r.p = next;
            r.s += 1;
            return .next;
        }

        /// Reads every star segment remaining in this component. The end
        /// is local to this scan: reused between segments, never carried
        /// through separators or stored in the reader's retry state.
        inline fn stars(r: *Self) Step {
            const pattern = r.pattern;
            const p = r.p;
            var q = p + 1;
            while (q < pattern.len and pattern[q] == '*') q += 1;
            if (separated and r.roles & Role.globstar != 0 and q - p >= 2 and
                (p == 0 or pattern[p - 1] == '/') and (q == pattern.len or pattern[q] == '/'))
            {
                return r.globstar(q);
            }
            const end = if (separated) Slashes.first(r.subject, r.s) orelse r.subject.len else r.subject.len;
            while (true) {
                if (q == pattern.len or (separated and pattern[q] == '/')) {
                    r.p = q;
                    r.s = end;
                    return .next;
                }
                const segment = Segment.read(separated, pattern, q, r.roles) orelse return .{ .done = .automaton };
                r.seen = @max(r.seen, segment.end);
                if (end - r.s < segment.units) return .fail;
                const at = if (segment.star)
                    r.first(segment, end) orelse return .fail
                else if (r.unitsAt(segment, end - segment.units))
                    end - segment.units
                else
                    return .fail;
                r.p = segment.end;
                r.s = at + segment.units;
                if (!segment.star) return .next;
                q = r.p + 1;
                while (q < pattern.len and pattern[q] == '*') q += 1;
            }
        }

        /// The first place at or after `s` where `segment` matches, ending
        /// by `end`.
        fn first(r: *const Self, segment: Segment, end: usize) ?usize {
            const lead = r.pattern[segment.start];
            const literal = Role.of[lead] & r.roles == 0;
            var at = r.s;
            while (at + segment.units <= end) : (at += 1) {
                if (literal and !same(fold, lead, r.subject[at])) continue;
                if (r.unitsAt(segment, at)) return at;
            }
            return null;
        }

        /// Whether `segment` matches the subject from `at`, inside one of
        /// its components.
        fn unitsAt(r: *const Self, segment: Segment, at: usize) bool {
            var i = segment.start;
            var j = at;
            while (i < segment.end) : (j += 1) {
                const c = r.pattern[i];
                const b = r.subject[j];
                switch (Role.of[c] & r.roles) {
                    0 => if (!same(fold, c, b)) return false,
                    Role.any => {},
                    Role.bracket => {
                        const close = bracketEnd(r.pattern, i).?;
                        if (!inBracket(r.pattern, i, close, b)) return false;
                        i = close;
                        continue;
                    },
                    else => unreachable,
                }
                i += 1;
            }
            return true;
        }

        /// Reads a `**` standing as a component and ending at `q`.
        inline fn globstar(r: *Self, q: usize) Step {
            // A trailing `**` takes whatever follows the separator before
            // it, nothing included.
            if (q == r.pattern.len) return .{ .done = .yes };
            r.p = q + 1;
            if (components(r.pattern[r.p..])) |count| {
                // The rest is the subject's last `count` components: one
                // try, and no earlier `**` can make it fit.
                r.deep_p = none;
                r.s = fromEnd(r.subject, r.s, count) orelse return .fail;
            } else {
                r.deep_p = r.p;
                r.deep = .init(r.subject, r.s);
            }
            return .next;
        }

        /// Moves to the next try, the last `**` taking one more component;
        /// false when there is none. A component that cannot start what
        /// follows the `**`, a literal, is passed over.
        inline fn retry(r: *Self) bool {
            if (r.deep_p == none) return false;
            // A `**/` that has a retry point has more pattern after it.
            const lead = r.pattern[r.deep_p];
            const literal = Role.of[lead] & r.roles == 0;
            while (true) {
                const start = (r.deep.next() orelse return false) + 1;
                if (!literal or (start < r.subject.len and same(fold, lead, r.subject[start]))) {
                    r.p = r.deep_p;
                    r.s = start;
                    return true;
                }
            }
        }
    };
}

/// The units after a run of stars, up to the next star, the component's
/// end or the pattern's: `pattern[start..end]`, each unit one byte wide.
const Segment = struct {
    start: usize,
    end: usize,
    units: usize,
    /// Another star follows.
    star: bool,

    /// The segment from `start`, or null when it holds something the
    /// reader hands on.
    fn read(comptime separated: bool, pattern: []const u8, start: usize, roles: u8) ?Segment {
        var units: usize = 0;
        var at = start;
        while (at < pattern.len) : (units += 1) {
            const role = Role.of[pattern[at]] & roles;
            if (role == 0 or role == Role.any) {
                at += 1;
            } else if (role == Role.star) {
                return .{ .start = start, .end = at, .units = units, .star = true };
            } else if (separated and role == Role.separator) {
                break;
            } else if (role == Role.bracket and roles & Role.read_brackets != 0) {
                at = bracketEnd(pattern, at) orelse return null;
            } else return null;
        }
        return .{ .start = start, .end = at, .units = units, .star = false };
    }
};

/// A pattern answered `.no` after reading `pattern[0..seen]`: the answer
/// stands when the rest holds nothing the automaton would read or refuse.
/// Most rests hold none of the bytes that could, which a few word
/// compares show.
inline fn settle(pattern: []const u8, seen: usize, roles: u8) Outcome {
    // A dialect with none of those bytes has nothing to look for.
    if (roles & Needles.checked == 0) return .no;
    return settleRest(pattern[seen..], roles);
}

noinline fn settleRest(rest: []const u8, roles: u8) Outcome {
    const needles = Needles.of(roles).?;
    if (!needles.anyIn(rest)) return .no;
    var at: usize = 0;
    while (at < rest.len) {
        const role = Role.of[rest[at]] & roles;
        if (role & Role.foreign != 0) return .automaton;
        if (role == Role.bracket) {
            if (roles & Role.read_brackets == 0) return .automaton;
            at = bracketEnd(rest, at) orelse return .automaton;
            continue;
        }
        at += 1;
    }
    return .no;
}

/// The bytes that can make the rest of a pattern invalid or the
/// automaton's, `[`, `\` and the braces as a dialect has them, each
/// repeated across a word to find them eight at a time.
const Needles = struct {
    words: [4]u64,

    const ones: u64 = 0x0101_0101_0101_0101;
    const highs: u64 = 0x8080_8080_8080_8080;
    const prefix: Needles = .{ .words = .{ ones * '*', ones * '?', ones * '[', ones * '\\' } };

    /// The roles whose bytes are needles, three bits in a row.
    const checked = Role.bracket | Role.escape | Role.brace;
    comptime {
        std.debug.assert(checked == 0b111 << 3);
    }

    const by_roles: [8]?Needles = table: {
        var t: [8]?Needles = undefined;
        for (&t, 0..) |*n, i| n.* = build(i << 3);
        break :table t;
    };

    /// Null when the dialect has none of them.
    fn of(roles: u8) ?Needles {
        return by_roles[(roles & checked) >> 3];
    }

    fn build(roles: u8) ?Needles {
        var bytes: [4]u8 = undefined;
        var len: usize = 0;
        if (roles & Role.bracket != 0) {
            bytes[len] = '[';
            len += 1;
        }
        if (roles & Role.escape != 0) {
            bytes[len] = '\\';
            len += 1;
        }
        if (roles & Role.brace != 0) {
            bytes[len..][0..2].* = "{}".*;
            len += 2;
        }
        if (len == 0) return null;
        var n: Needles = undefined;
        // Slots past the dialect's bytes repeat its first.
        for (&n.words, 0..) |*word, i| word.* = ones * (if (i < len) bytes[i] else bytes[0]);
        return n;
    }

    fn anyIn(n: Needles, bytes: []const u8) bool {
        if (bytes.len >= 8) {
            var at: usize = 0;
            while (at + 8 < bytes.len) : (at += 8) {
                if (n.inWord(std.mem.readInt(u64, bytes[at..][0..8], .little))) return true;
            }
            return n.inWord(std.mem.readInt(u64, bytes[bytes.len - 8 ..][0..8], .little));
        }
        if (bytes.len >= 4) {
            const low = std.mem.readInt(u32, bytes[0..4], .little);
            const high = std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little);
            return n.inWord(@as(u64, high) << 32 | low);
        }
        // Zero bytes pad the word: no needle is zero.
        var word: u64 = 0;
        for (bytes) |b| word = word << 8 | b;
        return n.inWord(word);
    }

    /// Whether some byte of `word` is a needle: a byte equal to one is
    /// zero after the exclusive or, and only a zero byte borrows into its
    /// high bit.
    fn inWord(n: Needles, word: u64) bool {
        var found: u64 = 0;
        for (n.words) |needle| {
            const x = word ^ needle;
            found |= (x -% ones) & ~x & highs;
        }
        return found != 0;
    }
};

/// How many components `rest` has, or null when one of them is `**`.
fn components(rest: []const u8) ?usize {
    var count: usize = 1;
    // The current component's length, and whether it is all stars.
    var len: usize = 0;
    var stars = true;
    for (rest) |c| {
        if (c == '/') {
            if (stars and len >= 2) return null;
            count += 1;
            len = 0;
            stars = true;
        } else {
            len += 1;
            stars = stars and c == '*';
        }
    }
    return if (stars and len >= 2) null else count;
}

/// Where the `count`th component from the end of `subject` starts, at or
/// after `from`, or null when fewer are left.
fn fromEnd(subject: []const u8, from: usize, count: usize) ?usize {
    var end = subject.len;
    var left = count;
    while (true) {
        const slash = Slashes.last(subject, from, end);
        left -= 1;
        if (left == 0) return if (slash) |i| i + 1 else from;
        end = slash orelse return null;
    }
}

/// Where the bracket opening at `open` ends (after its `]`), read by git's
/// procedure: an optional `!` or `^`, then members, the first taken whatever
/// it is, up to a `]`. Null for one the automaton reads: a named class, an
/// escape or a separator in it, or no `]`.
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

/// Whether `pattern` holds more than `most` brackets, or something this
/// executor hands on before they are counted.
noinline fn moreBrackets(pattern: []const u8, roles: u8, most: usize) bool {
    var count: usize = 0;
    var at: usize = 0;
    while (at < pattern.len) {
        const role = Role.of[pattern[at]] & roles;
        if (role & Role.foreign != 0) return true;
        if (role == Role.bracket) {
            if (roles & Role.read_brackets == 0) return true;
            at = bracketEnd(pattern, at) orelse return true;
            count += 1;
            if (count > most) return true;
            continue;
        }
        at += 1;
    }
    return false;
}

fn same(comptime fold: bool, a: u8, b: u8) bool {
    return if (fold) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

/// The separators in a subject from some place on, found eight bytes at a
/// time: components are short, and finding their ends is most of what a
/// path costs.
const Slashes = struct {
    subject: []const u8,
    /// Where the next word starts.
    at: usize,
    /// Where the current word starts, and its separators not yet given.
    base: usize = 0,
    found: u64 = 0,

    const ones: u64 = 0x0101_0101_0101_0101;
    const lows: u64 = 0x7f7f_7f7f_7f7f_7f7f;
    const splat: u64 = ones * '/';

    fn init(subject: []const u8, from: usize) Slashes {
        return .{ .subject = subject, .at = from };
    }

    /// The next separator.
    fn next(it: *Slashes) ?usize {
        while (it.found == 0) {
            const subject = it.subject;
            if (it.at >= subject.len) return null;
            it.base = it.at;
            if (it.at + 8 <= subject.len) {
                it.found = in(std.mem.readInt(u64, subject[it.at..][0..8], .little));
                it.at += 8;
            } else {
                it.found = in(tail(subject, it.at));
                it.at = subject.len;
            }
        }
        const slash = it.base + @ctz(it.found) / 8;
        it.found &= it.found - 1;
        return slash;
    }

    /// The first separator at or after `from`.
    fn first(subject: []const u8, from: usize) ?usize {
        var it: Slashes = .init(subject, from);
        return it.next();
    }

    /// The last separator in `subject[from..end]`.
    fn last(subject: []const u8, from: usize, end: usize) ?usize {
        var at = end;
        while (at >= from + 8) {
            at -= 8;
            const found = in(std.mem.readInt(u64, subject[at..][0..8], .little));
            if (found != 0) return at + 7 - @clz(found) / 8;
        }
        while (at > from) {
            at -= 1;
            if (subject[at] == '/') return at;
        }
        return null;
    }

    /// The fewer than eight bytes from `at` to the end as a word, with
    /// zero bytes after them: zero is no separator.
    fn tail(subject: []const u8, at: usize) u64 {
        if (subject.len >= 8) {
            // The last eight bytes, shifted past those before `at`.
            const base = subject.len - 8;
            return std.mem.readInt(u64, subject[base..][0..8], .little) >> @intCast(8 * (at - base));
        }
        var word: u64 = 0;
        var i = subject.len;
        while (i > at) {
            i -= 1;
            word = word << 8 | subject[i];
        }
        return word;
    }

    /// The high bit of each byte of `word` that is a separator, and of no
    /// other byte.
    fn in(word: u64) u64 {
        const x = word ^ splat;
        return ~(((x & lows) +% lows) | x | lows);
    }
};

test "separators are found word by word as one by one" {
    var prng: std.Random.DefaultPrng = .init(0x51a5);
    const random = prng.random();
    var buffer: [40]u8 = undefined;
    for (0..4000) |_| {
        const subject = buffer[0..random.uintAtMost(usize, buffer.len)];
        for (subject) |*c| c.* = if (random.uintLessThan(u8, 4) == 0) '/' else "a*\x00\xff"[random.uintLessThan(usize, 4)];
        const from = random.uintAtMost(usize, subject.len);
        var it: Slashes = .init(subject, from);
        var at = from;
        while (std.mem.findScalarPos(u8, subject, at, '/')) |want| : (at = want + 1) {
            try std.testing.expectEqual(@as(?usize, want), it.next());
        }
        try std.testing.expectEqual(@as(?usize, null), it.next());
        const end = from + random.uintAtMost(usize, subject.len - from);
        const want = if (std.mem.findScalarLast(u8, subject[from..end], '/')) |i| from + i else null;
        try std.testing.expectEqual(want, Slashes.last(subject, from, end));
    }
}
