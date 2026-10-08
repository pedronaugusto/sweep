//! A naive matcher for every dialect, written from the README's rules and
//! nothing else: the oracle the differential tests hold the automaton to.
//!
//! Braces are expanded into every flat token sequence, and each sequence is
//! matched by plain backtracking. Both are exponential, which is fine on
//! the short inputs the tests give it.
const std = @import("std");
const sweep = @import("../sweep.zig");

const Code = u32;
const ill_formed: Code = 0x110000;

pub const Answer = enum { no, yes, invalid };

const Token = union(enum) {
    lit: struct { code: Code, escaped: bool },
    sep: struct { escaped: bool },
    any,
    stars: usize,
    /// `anywhere`: zero or more whole components, whatever `globstar` says.
    components,
    /// Index into the bracket list.
    bracket: usize,
    /// Index into the group list.
    group: usize,
};

const Bracket = struct {
    negated: bool,
    /// Members as written, read again for every unit.
    members: []const Member,
};

const Member = union(enum) {
    single: Code,
    range: struct { lo: Code, hi: Code },
    posix: []const u8,
};

const Group = struct {
    alternatives: []const []const Token,
};

const Tokens = struct {
    a: std.mem.Allocator,
    brackets: std.ArrayList(Bracket) = .empty,
    groups: std.ArrayList(Group) = .empty,
};

const Invalid = error{Invalid};
const Error = Invalid || std.mem.Allocator.Error;

fn decode(utf8: bool, bytes: []const u8, at: usize) struct { code: Code, len: usize } {
    const first = bytes[at];
    if (!utf8 or first < 0x80) return .{ .code = first, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(first) catch return .{ .code = ill_formed + first, .len = 1 };
    if (len > bytes.len - at) return .{ .code = ill_formed + first, .len = 1 };
    if (!std.unicode.utf8ValidateSlice(bytes[at..][0..len])) return .{ .code = ill_formed + first, .len = 1 };
    var scalar: Code = first & (@as(u8, 0x7f) >> len);
    for (bytes[at + 1 ..][0 .. len - 1]) |b| scalar = scalar << 6 | (b & 0x3f);
    return .{ .code = scalar, .len = len };
}

fn sepCode(options: sweep.Options) ?Code {
    const s = options.syntax.separator orelse return null;
    return if (options.syntax.unit == .utf8 and s >= 0x80) ill_formed + s else s;
}

/// Reads `pattern[at..]` up to the end, or to the `,`/`}` closing the group
/// it is in when `depth > 0`.
fn tokenize(t: *Tokens, pattern: []const u8, at_in: *usize, options: sweep.Options, depth: usize) Error![]const Token {
    const sx = options.syntax;
    const utf8 = sx.unit == .utf8;
    var list: std.ArrayList(Token) = .empty;
    var at = at_in.*;
    while (at < pattern.len) {
        const c = pattern[at];
        if (sx.escape and c == '\\') {
            if (at + 1 >= pattern.len) return error.Invalid;
            const u = decode(utf8, pattern, at + 1);
            if (sepCode(options) == u.code) {
                try list.append(t.a, .{ .sep = .{ .escaped = true } });
            } else try list.append(t.a, .{ .lit = .{ .code = u.code, .escaped = true } });
            at += 1 + u.len;
        } else if (c == '*') {
            var j = at;
            while (j < pattern.len and pattern[j] == '*') j += 1;
            try list.append(t.a, .{ .stars = j - at });
            at = j;
        } else if (c == '?') {
            try list.append(t.a, .any);
            at += 1;
        } else if (c == '[' and sx.brackets != .none) {
            if (try readBracket(t, pattern, at, options)) |r| {
                try list.append(t.a, .{ .bracket = r.index });
                at = r.next;
            } else {
                try list.append(t.a, .{ .lit = .{ .code = '[', .escaped = false } });
                at += 1;
            }
        } else if (sx.braces and c == '{') {
            at += 1;
            var alternatives: std.ArrayList([]const Token) = .empty;
            while (true) {
                const alt = try tokenize(t, pattern, &at, options, depth + 1);
                try alternatives.append(t.a, alt);
                if (at >= pattern.len) return error.Invalid;
                const closer = pattern[at];
                at += 1;
                if (closer == '}') break;
            }
            try t.groups.append(t.a, .{ .alternatives = alternatives.items });
            try list.append(t.a, .{ .group = t.groups.items.len - 1 });
        } else if (sx.braces and (c == '}' or (c == ',' and depth > 0))) {
            if (depth == 0) return error.Invalid;
            break;
        } else {
            const u = decode(utf8, pattern, at);
            if (sepCode(options) == u.code) {
                try list.append(t.a, .{ .sep = .{ .escaped = false } });
            } else try list.append(t.a, .{ .lit = .{ .code = u.code, .escaped = false } });
            at += u.len;
        }
    }
    at_in.* = at;
    return list.items;
}

/// git's bracket reading, over units. Null for an unclosed bracket under
/// lenient brackets.
fn readBracket(t: *Tokens, pattern: []const u8, start: usize, options: sweep.Options) Error!?struct { index: usize, next: usize } {
    const sx = options.syntax;
    const utf8 = sx.unit == .utf8;
    var members: std.ArrayList(Member) = .empty;
    var p = start + 1;
    var negated = false;
    if (p < pattern.len and (pattern[p] == '!' or pattern[p] == '^')) {
        negated = true;
        p += 1;
    }
    var prev: Code = 0;
    while (true) {
        if (p >= pattern.len) return if (sx.brackets == .lenient) null else error.Invalid;
        var current: Code = undefined;
        var adv: usize = 1;
        if (sx.escape and pattern[p] == '\\') {
            p += 1;
            if (p >= pattern.len) return if (sx.brackets == .lenient) null else error.Invalid;
            const u = decode(utf8, pattern, p);
            try members.append(t.a, .{ .single = u.code });
            current = u.code;
            adv = u.len;
        } else if (pattern[p] == '-' and prev != 0 and p + 1 < pattern.len and pattern[p + 1] != ']') {
            p += 1;
            var high = decode(utf8, pattern, p);
            if (sx.escape and pattern[p] == '\\') {
                p += 1;
                if (p >= pattern.len) return if (sx.brackets == .lenient) null else error.Invalid;
                high = decode(utf8, pattern, p);
            }
            try members.append(t.a, .{ .range = .{ .lo = prev, .hi = high.code } });
            current = 0;
            adv = high.len;
        } else if (pattern[p] == '[' and p + 1 < pattern.len and pattern[p + 1] == ':') {
            const end = std.mem.findScalarPos(u8, pattern, p + 2, ']') orelse
                return if (sx.brackets == .lenient) null else error.Invalid;
            if (end < p + 3 or pattern[end - 1] != ':') {
                try members.append(t.a, .{ .single = '[' });
                current = '[';
            } else {
                const name = pattern[p + 2 .. end - 1];
                if (!knownClass(name)) return error.Invalid;
                try members.append(t.a, .{ .posix = name });
                p = end;
                current = 0;
            }
        } else {
            const u = decode(utf8, pattern, p);
            try members.append(t.a, .{ .single = u.code });
            current = u.code;
            adv = u.len;
        }
        prev = current;
        p += adv;
        if (p < pattern.len and pattern[p] == ']') break;
    }
    try t.brackets.append(t.a, .{ .negated = negated, .members = members.items });
    return .{ .index = t.brackets.items.len - 1, .next = p + 1 };
}

const class_names = [_][]const u8{ "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "xdigit" };

fn knownClass(name: []const u8) bool {
    for (class_names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn inClass(name: []const u8, code: Code, git_fold: bool) bool {
    if (code >= 128) return false;
    const c: u8 = @intCast(code);
    if (std.mem.eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (std.mem.eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (std.mem.eql(u8, name, "cntrl")) return c < 0x20 or c == 0x7f;
    if (std.mem.eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (std.mem.eql(u8, name, "graph")) return c > 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "lower")) return std.ascii.isLower(c);
    if (std.mem.eql(u8, name, "print")) return c >= 0x20 and c < 0x7f;
    if (std.mem.eql(u8, name, "punct")) return c > 0x20 and c < 0x7f and !std.ascii.isAlphanumeric(c);
    if (std.mem.eql(u8, name, "space")) return c == ' ' or (c >= '\t' and c <= '\r');
    if (std.mem.eql(u8, name, "upper")) return std.ascii.isUpper(c) or (git_fold and std.ascii.isLower(c));
    if (std.mem.eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    unreachable;
}

fn lower(c: Code) Code {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn swap(c: Code) Code {
    if (c >= 'A' and c <= 'Z') return c + 32;
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

/// Whether the members match `code` compared as written.
fn membersMatch(b: Bracket, code: Code, git_fold: bool) bool {
    for (b.members) |m| switch (m) {
        .single => |s| if (s == code) return true,
        .range => |r| {
            if (code >= r.lo and code <= r.hi) return true;
            if (git_fold and code >= 'a' and code <= 'z' and code - 32 >= r.lo and code - 32 <= r.hi) return true;
        },
        .posix => |name| if (inClass(name, code, git_fold)) return true,
    };
    return false;
}

fn bracketHas(b: Bracket, code: Code, case: sweep.Case) bool {
    const positive = switch (case) {
        .unicode => unreachable,
        .sensitive => membersMatch(b, code, false),
        .ascii => membersMatch(b, code, false) or membersMatch(b, swap(code), false),
        // git folds the text and compares members unfolded.
        .ascii_git => membersMatch(b, lower(code), true),
    };
    return positive != b.negated;
}

const Flat = []const Token;

/// Every flat token sequence the groups expand to.
fn expand(t: *Tokens, seq: []const Token, out: *std.ArrayList(Flat)) Error!void {
    var partial: std.ArrayList(std.ArrayList(Token)) = .empty;
    try partial.append(t.a, .empty);
    for (seq) |tok| switch (tok) {
        .group => |g| {
            var next: std.ArrayList(std.ArrayList(Token)) = .empty;
            for (t.groups.items[g].alternatives) |alt| {
                var alts: std.ArrayList(Flat) = .empty;
                try expand(t, alt, &alts);
                for (partial.items) |prefix| for (alts.items) |tail| {
                    var joined: std.ArrayList(Token) = .empty;
                    try joined.appendSlice(t.a, prefix.items);
                    try joined.appendSlice(t.a, tail);
                    try next.append(t.a, joined);
                };
            }
            partial = next;
            if (partial.items.len > 4096) return error.Invalid;
        },
        else => for (partial.items) |*p| try p.append(t.a, tok),
    };
    for (partial.items) |p| try out.append(t.a, p.items);
}

const Matcher = struct {
    t: *Tokens,
    options: sweep.Options,
    units: []const Code,
    sep: ?Code,

    fn isSep(m: *const Matcher, code: Code) bool {
        return if (m.sep) |s| s == code else false;
    }

    /// Whether position `at` begins a component.
    fn atStart(m: *const Matcher, at: usize) bool {
        return at == 0 or m.isSep(m.units[at - 1]);
    }

    fn hidden(m: *const Matcher, at: usize) bool {
        return m.options.syntax.leading_dot == .explicit and m.units[at] == '.' and m.atStart(at);
    }

    fn litMatches(m: *const Matcher, code: Code, escaped: bool, text: Code) bool {
        return switch (m.options.case) {
            .unicode => unreachable,
            .sensitive => code == text,
            .ascii => lower(code) == lower(text),
            .ascii_git => (if (escaped) code else lower(code)) == lower(text),
        };
    }

    fn globstar(m: *const Matcher, seq: Flat, i: usize, count: usize) bool {
        const sx = m.options.syntax;
        if (count < 2 or sx.separator == null) return false;
        if (sx.globstar != .component) return false;
        const before = i == 0 or seq[i - 1] == .sep or seq[i - 1] == .components;
        const after = i + 1 == seq.len or seq[i + 1] == .sep;
        return before and after;
    }

    fn run(m: *const Matcher, seq: Flat, i: usize, at: usize) bool {
        if (i == seq.len) return at == m.units.len;
        switch (seq[i]) {
            .group => unreachable,
            .components => {
                if (m.run(seq, i + 1, at)) return true;
                var end = at;
                while (end < m.units.len and !m.hidden(end)) {
                    end += 1;
                    if (m.isSep(m.units[end - 1]) and m.run(seq, i + 1, end)) return true;
                }
                return false;
            },
            .lit => |l| {
                if (at >= m.units.len or !m.litMatches(l.code, l.escaped, m.units[at])) return false;
                if (m.hidden(at)) {
                    // Only a `.` that begins a pattern component.
                    if (!(i == 0 or seq[i - 1] == .sep or seq[i - 1] == .components)) return false;
                }
                return m.run(seq, i + 1, at + 1);
            },
            .sep => {
                if (at >= m.units.len or !m.isSep(m.units[at])) return false;
                return m.run(seq, i + 1, at + 1);
            },
            .any => {
                if (at >= m.units.len or m.isSep(m.units[at]) or m.hidden(at)) return false;
                return m.run(seq, i + 1, at + 1);
            },
            .bracket => |b| {
                if (at >= m.units.len or m.isSep(m.units[at]) or m.hidden(at)) return false;
                if (!bracketHas(m.t.brackets.items[b], m.units[at], m.options.case)) return false;
                return m.run(seq, i + 1, at + 1);
            },
            .stars => |count| {
                const sx = m.options.syntax;
                const crosses = sx.separator == null or (count >= 2 and sx.globstar == .anywhere);
                if (m.globstar(seq, i, count)) {
                    // `**/`: zero whole components, then the rest after the `/`.
                    if (i + 1 < seq.len and !seq[i + 1].sep.escaped and m.run(seq, i + 2, at)) return true;
                    var end = at;
                    while (true) {
                        if (m.run(seq, i + 1, end)) return true;
                        if (end >= m.units.len or m.hidden(end)) return false;
                        end += 1;
                    }
                }
                var end = at;
                while (true) {
                    if (m.run(seq, i + 1, end)) return true;
                    if (end >= m.units.len or m.hidden(end)) return false;
                    if (!crosses and m.isSep(m.units[end])) return false;
                    end += 1;
                }
            },
        }
    }
};

/// What `pattern` against `subject` gives under `options`.
pub fn match(gpa: std.mem.Allocator, pattern: []const u8, subject: []const u8, options: sweep.Options) Answer {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return matchIn(arena.allocator(), pattern, subject, options) catch |err| switch (err) {
        error.Invalid => .invalid,
        error.OutOfMemory => @panic("oracle out of memory"),
    };
}

fn matchIn(a: std.mem.Allocator, pattern: []const u8, subject: []const u8, options: sweep.Options) Error!Answer {
    var t: Tokens = .{ .a = a };
    var at: usize = 0;
    var seq = try tokenize(&t, pattern, &at, options, 0);
    const sx = options.syntax;
    if (options.anywhere and sx.separator != null and std.mem.findScalar(u8, pattern, sx.separator.?) == null) {
        var prefixed: std.ArrayList(Token) = .empty;
        try prefixed.append(a, .components);
        try prefixed.appendSlice(a, seq);
        seq = prefixed.items;
    }
    var flats: std.ArrayList(Flat) = .empty;
    try expand(&t, seq, &flats);
    var units: std.ArrayList(Code) = .empty;
    var i: usize = 0;
    while (i < subject.len) {
        const u = decode(sx.unit == .utf8, subject, i);
        try units.append(a, u.code);
        i += u.len;
    }
    const m: Matcher = .{ .t = &t, .options = options, .units = units.items, .sep = sepCode(options) };
    for (flats.items) |flat| if (m.run(flat, 0, 0)) return .yes;
    return .no;
}
