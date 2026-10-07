//! The one parser: every dialect, one forward pass, no recursion. Braces
//! use an explicit stack of open groups; brackets are read by git's own
//! procedure and turned into a class by the dialect's case rule.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program = @import("program.zig");
const class_mod = @import("class.zig");

const Builder = program.Builder;
const Node = program.Node;
const Code = unit.Code;

pub const Error = syntax.PatternError;

/// What the accept node of a parsed pattern reports.
pub const Entry = struct {
    index: u27 = 0,
    dir_only: bool = false,
};

/// Parses `pattern` and appends its automaton to `b`, ending in an accept
/// for `entry`. On error the builder may hold a partial program; the
/// caller restores its lengths.
pub fn parse(b: *Builder, pattern: []const u8, options: syntax.Options, entry: Entry) Error!void {
    var p: Parser = .{ .b = b, .pattern = pattern, .options = options, .reading = .of(options) };
    p.run(entry) catch |err| switch (err) {
        error.Full => return p.tooLong(),
        error.InvalidPattern => return error.InvalidPattern,
    };
}

/// Whether `pattern` holds the separator byte anywhere, escaped or inside a
/// bracket included: then `anywhere` changes nothing.
pub fn hasSeparator(pattern: []const u8, sx: syntax.Syntax) bool {
    const sep = sx.separator orelse return true;
    return std.mem.findScalar(u8, pattern, sep) != null;
}

/// What the parser last read, for deciding whether `**` stands as a whole
/// component.
const Last = enum {
    /// Nothing: the pattern's start.
    start,
    /// A separator, escaped or not.
    sep,
    /// A brace boundary: what stood before depends on the alternative.
    open,
    /// Anything else.
    other,
};

const Tri = enum { yes, no, maybe };

const Parser = struct {
    b: *Builder,
    pattern: []const u8,
    options: syntax.Options,
    reading: program.Reading,
    depth: usize = 0,
    last: Last = .start,
    /// Where parsing stands, for a diagnostic.
    at: usize = 0,

    const RunError = error{ Full, InvalidPattern };

    fn run(p: *Parser, entry: Entry) RunError!void {
        const sx = p.options.syntax;
        // A hidden leading dot makes every wildcard look one unit back.
        if (p.reading.leading_dot) p.b.uses_start = true;
        if (p.options.anywhere and !hasSeparator(p.pattern, sx)) {
            // `**/` before a pattern that can only match one component.
            _ = try p.b.emit(.gstar, 0);
            _ = try p.b.emit(.sep, 0);
            p.b.uses_start = true;
            p.last = .sep;
        }
        const pattern = p.pattern;
        var i: usize = 0;
        while (i < pattern.len) {
            p.at = i;
            const c = pattern[i];
            if (sx.escape and c == '\\') {
                if (i + 1 >= pattern.len) return p.fail(.trailing_escape, i);
                const u = p.decode(i + 1);
                if (p.reading.isSeparator(u.code)) {
                    _ = try p.b.emit(.sep, 1);
                    p.last = .sep;
                } else try p.literal(u.code, true);
                i += 1 + u.len;
            } else if (c == '*') {
                var j = i;
                while (j < pattern.len and pattern[j] == '*') j += 1;
                try p.stars(j - i, j);
                i = j;
            } else if (c == '?') {
                _ = try p.b.emit(.any, 0);
                p.last = .other;
                i += 1;
            } else if (c == '[' and sx.brackets != .none) {
                i = try p.bracket(i);
            } else if (sx.braces and c == '{') {
                try p.open(i);
                i += 1;
            } else if (sx.braces and c == ',' and p.depth > 0) {
                try p.alternative();
                i += 1;
            } else if (sx.braces and c == '}') {
                if (p.depth == 0) return p.fail(.unmatched_brace, i);
                p.close();
                i += 1;
            } else {
                const u = p.decode(i);
                if (p.reading.isSeparator(u.code)) {
                    _ = try p.b.emit(.sep, 0);
                    p.last = .sep;
                } else try p.literal(u.code, false);
                i += u.len;
            }
        }
        p.at = pattern.len;
        if (p.depth > 0) return p.fail(.unclosed_brace, p.b.frames[p.depth - 1].offset);
        _ = try p.b.emit(.accept, @as(u28, entry.index) << 1 | @intFromBool(entry.dir_only));
    }

    fn decode(p: *const Parser, at: usize) unit.Unit {
        return unit.decode(p.reading.utf8, p.pattern, at);
    }

    fn literal(p: *Parser, code: Code, escaped: bool) RunError!void {
        const canon = switch (p.options.case) {
            .sensitive => code,
            .ascii => unit.fold(code),
            // git compares an escaped pattern byte unfolded against the
            // folded text, so an escaped capital matches nothing.
            .ascii_git => if (escaped) code else unit.fold(code),
        };
        if (p.reading.leading_dot and code == '.') {
            _ = try p.b.emit(.dot, 0);
            _ = try p.b.emit(.dot_plain, 0);
            p.b.uses_start = true;
        } else {
            _ = try p.b.emit(.lit, @intCast(canon));
        }
        p.last = .other;
    }

    fn stars(p: *Parser, count: usize, after: usize) RunError!void {
        const sx = p.options.syntax;
        const last = p.last;
        p.last = .other;
        if (count == 1 or sx.separator == null or sx.globstar == .off) {
            _ = try p.b.emit(.star, @intFromBool(sx.separator == null));
            return;
        }
        if (sx.globstar == .anywhere) {
            _ = try p.b.emit(.star, 1);
            return;
        }
        const before: Tri = switch (last) {
            .start, .sep => .yes,
            .open => .maybe,
            .other => .no,
        };
        const behind = p.follows(after);
        if (before == .no or behind == .no) {
            _ = try p.b.emit(.star, 0);
            return;
        } else if (before == .yes and behind == .yes) {
            _ = try p.b.emit(.gstar, 0);
        } else {
            // Which alternative led here, or follows, decides: both readings
            // run, and the contexts let only the right one through. A star
            // matches a subset of what the globstar matches, so where both
            // apply the union is the globstar's answer.
            const split = try p.b.emit(.split, 0);
            _ = try p.b.emit(.gstar, 1);
            _ = try p.b.emit(.star, 0);
            p.b.nodes[split].arg = @intCast(split + 2);
        }
        p.b.uses_start = true;
    }

    /// Whether what follows a `**` ending at `at` ends a component.
    fn follows(p: *const Parser, at: usize) Tri {
        const sx = p.options.syntax;
        const pattern = p.pattern;
        if (at >= pattern.len) return .yes;
        if (p.reading.isSeparator(p.decode(at).code)) return .yes;
        if (sx.escape and pattern[at] == '\\' and at + 1 < pattern.len and p.reading.isSeparator(p.decode(at + 1).code)) return .yes;
        if (sx.braces) switch (pattern[at]) {
            '{', '}' => return .maybe,
            ',' => if (p.depth > 0) return .maybe,
            else => {},
        };
        return .no;
    }

    /// Reads the bracket at `i` and returns where parsing goes on.
    fn bracket(p: *Parser, i: usize) RunError!usize {
        const sx = p.options.syntax;
        const pattern = p.pattern;
        const b = p.b;
        if (b.class_len >= b.classes.len) return error.Full;
        var filler: class_mod.Filler = .init(b.ranges, @intCast(b.range_len), p.options.case);
        var at = i + 1;
        if (at < pattern.len and (pattern[at] == '!' or pattern[at] == '^')) at += 1;
        const negated = at > i + 1;
        // git's `prev`: the last member that may open a range, 0 for none.
        var prev: Code = 0;
        while (true) {
            if (at >= pattern.len) return p.unclosed(i);
            const c = pattern[at];
            var current: Code = undefined;
            var step: usize = 1;
            if (sx.escape and c == '\\') {
                at += 1;
                if (at >= pattern.len) return p.unclosed(i);
                const u = p.decode(at);
                filler.single(u.code);
                current = u.code;
                step = u.len;
            } else if (c == '-' and prev != 0 and at + 1 < pattern.len and pattern[at + 1] != ']') {
                at += 1;
                var high = p.decode(at);
                if (sx.escape and pattern[at] == '\\') {
                    at += 1;
                    if (at >= pattern.len) return p.unclosed(i);
                    high = p.decode(at);
                }
                filler.range(prev, high.code);
                current = 0;
                step = high.len;
            } else if (c == '[' and at + 1 < pattern.len and pattern[at + 1] == ':') {
                const name_start = at + 2;
                const end = std.mem.findScalarPos(u8, pattern, name_start, ']') orelse return p.unclosed(i);
                if (end < name_start + 1 or pattern[end - 1] != ':') {
                    // No `:]`: the `[` is a member, and the `:` is next.
                    filler.single('[');
                    current = '[';
                } else {
                    const named = class_mod.Posix.named(pattern[name_start .. end - 1]) orelse
                        return p.fail(.unknown_class, at);
                    filler.posix(named);
                    at = end;
                    current = 0;
                }
            } else {
                const u = p.decode(at);
                filler.single(u.code);
                current = u.code;
                step = u.len;
            }
            prev = current;
            at += step;
            if (at < pattern.len and pattern[at] == ']') break;
        }
        const class = filler.finish(negated, p.reading.separator);
        if (filler.overflow) return error.Full;
        b.classes[b.class_len] = class;
        b.range_len = class.first + class.count;
        _ = try b.emit(.class, @intCast(b.class_len));
        b.class_len += 1;
        p.last = .other;
        return at + 1;
    }

    /// A `[` with no closing `]`: an error, or a literal `[` when lenient.
    fn unclosed(p: *Parser, i: usize) RunError!usize {
        if (p.options.syntax.brackets != .lenient) return p.fail(.unclosed_bracket, i);
        try p.literal('[', false);
        return i + 1;
    }

    fn open(p: *Parser, i: usize) RunError!void {
        const b = p.b;
        if (p.depth >= b.frames.len) return error.Full;
        const split = try b.emit(.split, 0);
        b.frames[p.depth] = .{ .split = split, .jumps = program.no_jump, .offset = @intCast(i) };
        p.depth += 1;
        p.last = .open;
    }

    fn alternative(p: *Parser) RunError!void {
        const b = p.b;
        const frame = &b.frames[p.depth - 1];
        const jump = try b.emit(.jump, @intCast(frame.jumps));
        frame.jumps = jump;
        b.nodes[frame.split].arg = @intCast(b.node_len);
        frame.split = try b.emit(.split, 0);
        p.last = .open;
    }

    fn close(p: *Parser) void {
        const b = p.b;
        const frame = b.frames[p.depth - 1];
        // The last alternative needs no split: it falls through.
        b.nodes[frame.split] = .{ .op = .jump, .arg = @intCast(frame.split + 1) };
        var jump = frame.jumps;
        while (jump != program.no_jump) {
            const next = b.nodes[jump].arg;
            b.nodes[jump].arg = @intCast(b.node_len);
            jump = next;
        }
        p.depth -= 1;
        p.last = .open;
    }

    fn tooLong(p: *Parser) Error {
        if (p.options.diagnostics) |d| d.* = .{ .offset = p.at, .reason = .too_long };
        return error.PatternTooLong;
    }

    fn fail(p: *Parser, reason: syntax.Diagnostics.Reason, offset: usize) error{InvalidPattern} {
        if (p.options.diagnostics) |d| d.* = .{ .offset = offset, .reason = reason };
        return error.InvalidPattern;
    }
};
