//! The one parser: every dialect, one forward pass, no recursion. Braces
//! and extglobs use an explicit stack of open groups; brackets are read by git's own
//! procedure and turned into a class by the dialect's case rule.
const std = @import("std");
const aegis = @import("aegis");
const normal = @import("normal.zig");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program = @import("program.zig");
const class_mod = @import("class.zig");
const integer = @import("integer.zig");
const unicode = @import("unicode.zig");

const Builder = program.Builder;
const Node = program.Node;
const Code = unit.Code;

pub const Error = syntax.PatternError;

pub const AcceptIndex = aegis.int.Ranged(u32, 0, (1 << 27) - 1);

/// What the accept node of a parsed pattern reports.
pub const Entry = struct {
    index: AcceptIndex = AcceptIndex.init(0) catch unreachable, // unreachable: zero is within the declared encoding range
    dir_only: bool = false,
};

/// Parses `pattern` and appends its automaton to `b`, ending in an accept
/// for `entry`. On error the builder may hold a partial program; the
/// caller restores its lengths.
pub fn parse(b: *Builder, pattern: []const u8, options: syntax.Options, entry: Entry) Error!void {
    var p: Parser = .{ .b = b, .pattern = pattern, .options = options, .reading = .of(options) };
    if (options.syntax.single_brace_literal and !pairedBraces(pattern, options.syntax)) p.options.syntax.braces = false;
    p.run(entry) catch |err| switch (err) {
        error.Full => return p.tooLong(),
        error.InvalidPattern => return error.InvalidPattern,
    };
}

/// Whether `pattern` holds the separator byte anywhere, escaped or inside a
/// bracket included: then `anywhere` changes nothing.
pub fn hasSeparator(pattern: []const u8, sx: syntax.Syntax) bool {
    const sep = sx.separator orelse return true;
    if (sx.alternate_separator) |alt| if (std.mem.findScalar(u8, pattern, alt) != null) return true;
    if (!sx.bracket_separator_literal or sx.brackets == .none) return std.mem.findScalar(u8, pattern, sep) != null;
    var in_bracket = false;
    for (pattern) |byte| {
        if (byte == '[') in_bracket = true;
        if (byte == ']') in_bracket = false;
        if (byte == sep and !in_bracket) return true;
    }
    return false;
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

// aegis: measured-boundary: docs/design.md#safety-boundaries; source and scratch cursors are bounded by their slices before each read or emit.
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
        const extended = p.b.capture or sx.extglob or sx.numeric_ranges or sx.bracket_separator_literal;
        if (p.reading.nfc) return if (extended) p.items(true, true, entry) else p.items(false, true, entry);
        return if (extended) p.items(true, false, entry) else p.items(false, false, entry);
    }

    // Ordinary dialects do not test numeric/extglob/capture rules per byte.
    // Both paths use the same parser and emit the same ordinary instructions.
    fn items(p: *Parser, comptime extended: bool, comptime normalized: bool, entry: Entry) RunError!void {
        const sx = p.options.syntax;
        // A hidden leading dot makes every wildcard look one unit back.
        if (p.reading.leading_dot) p.b.uses_start = true;
        if ((p.options.anywhere or sx.basename) and !hasSeparator(p.pattern, sx)) {
            // `**/` before a pattern that can only match one component.
            _ = try p.b.emit(.gstar, 0);
            _ = try p.b.emit(.sep, 0);
            p.b.uses_start = true;
            p.last = .sep;
        }
        const pattern = p.pattern;
        var i: usize = if (sx.root_slash and pattern.len > 0 and p.reading.isSeparator(pattern[0])) 1 else 0;
        while (i < pattern.len) {
            p.at = i;
            const c = pattern[i];
            if (normalized and p.literalStart(i)) {
                i = try p.normalLiterals(i);
                continue;
            }
            if (extended and sx.extglob and c == '!' and i + 1 < pattern.len and pattern[i + 1] == '(') return p.fail(.unsupported_extglob, i);
            const literal_bracket = if (extended and c == '[' and sx.brackets != .none and sx.bracket_separator_literal) separatorBracket(pattern, i, sx) else null;
            const interval = if (extended and c == '{' and sx.numeric_ranges) integer.read(pattern, i) catch return p.fail(.invalid_range, i) else null;
            const group = ((sx.braces and c == '{') or interval != null) or (extended and sx.extglob and i + 1 < pattern.len and pattern[i + 1] == '(' and std.mem.findScalar(u8, "?*+@", c) != null);
            const capture = if (extended and (group or c == '*' or c == '?' or (c == '[' and sx.brackets != .none and literal_bracket == null))) try p.startCapture() else null;
            if (extended and sx.extglob and i + 1 < pattern.len and pattern[i + 1] == '(' and std.mem.findScalar(u8, "?*+@", c) != null) {
                const bypass = try p.b.emit(.split, 0);
                try p.open(i);
                const frame = &p.b.frames[p.depth - 1];
                frame.head = bypass;
                frame.capture = capture;
                frame.kind = switch (c) {
                    '?' => .optional,
                    '*' => .zero_more,
                    '+' => .one_more,
                    '@' => .one,
                    else => unreachable,
                };
                i += 2;
            } else if (extended and sx.extglob and c == '|' and p.depth > 0 and p.b.frames[p.depth - 1].kind != .brace) {
                try p.alternative();
                i += 1;
            } else if (extended and sx.extglob and c == ')' and p.depth > 0 and p.b.frames[p.depth - 1].kind != .brace) {
                const frame = p.b.frames[p.depth - 1];
                try p.close();
                if (frame.kind == .zero_more or frame.kind == .one_more) {
                    _ = try p.b.emit(.split, try program.operandAfter(frame.head, 1));
                    p.b.cyclic = true;
                }
                if (frame.kind == .optional or frame.kind == .zero_more) {
                    p.b.nodes[frame.head.raw()].arg = @intCast(p.b.node_len); // safe: emit bounds every node position
                } else p.b.nodes[frame.head.raw()] = .{ .op = .jump, .arg = try program.operandAfter(frame.head, 1) };
                try p.endCapture(frame.capture);
                i += 1;
            } else if (sx.escape and c == '\\') {
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
            } else if (literal_bracket) |end| {
                while (i < end) {
                    const escaped = sx.escape and pattern[i] == '\\' and i + 1 < end;
                    const u = p.decode(i + @intFromBool(escaped));
                    if (p.reading.isSeparator(u.code)) {
                        _ = try p.b.emit(.sep, @intFromBool(escaped));
                        p.last = .sep;
                    } else try p.literal(u.code, escaped);
                    i += u.len + @intFromBool(escaped);
                }
            } else if (c == '[' and sx.brackets != .none) {
                i = try p.bracket(normalized, i);
            } else if (interval) |range| {
                try integer.compile(p.b, range);
                p.last = .other;
                try p.endCapture(capture);
                i = range.end;
            } else if (sx.braces and c == '{') {
                try p.open(i);
                p.b.frames[p.depth - 1].capture = capture;
                i += 1;
            } else if (sx.braces and c == ',' and p.depth > 0 and p.b.frames[p.depth - 1].kind == .brace) {
                try p.alternative();
                i += 1;
            } else if (sx.braces and c == '}') {
                if (p.depth == 0 or p.b.frames[p.depth - 1].kind != .brace) return p.fail(.unmatched_brace, i);
                const frame = p.b.frames[p.depth - 1];
                try p.close();
                try p.endCapture(frame.capture);
                i += 1;
            } else {
                const u = p.decode(i);
                if (p.reading.isSeparator(u.code)) {
                    _ = try p.b.emit(.sep, 0);
                    p.last = .sep;
                } else try p.literal(u.code, false);
                i += u.len;
            }
            if (!group) try p.endCapture(capture);
        }
        p.at = pattern.len;
        if (p.depth > 0) return p.fail(if (p.b.frames[p.depth - 1].kind == .brace) .unclosed_brace else .unclosed_extglob, p.b.frames[p.depth - 1].offset.raw());
        // The index is within 27 bits, so the directory bit packs beside it.
        const shifted = aegis.int.Checked(u32).init(entry.index.raw()).shl(1) catch return error.Full;
        _ = try p.b.emit(.accept, aegis.int.cast(u28, shifted.raw() | @intFromBool(entry.dir_only)) catch return error.Full);
    }

    // aegis: design: docs/design.md#safety-boundaries; capture ordinals are issued only during the bounded tagged-program build.
    fn startCapture(p: *Parser) RunError!?u32 {
        if (!p.b.capture) return null;
        const id = p.b.capture_count;
        p.b.capture_count += 1;
        _ = try p.b.emit(.save, @intCast(2 * id));
        return id;
    }

    fn endCapture(p: *Parser, id: ?u32) RunError!void {
        if (id) |capture| _ = try p.b.emit(.save, @intCast(2 * capture + 1));
    }

    fn literalStart(p: *const Parser, at: usize) bool {
        const c = p.pattern[at];
        const sx = p.options.syntax;
        if (sx.escape and c == '\\') return at + 1 < p.pattern.len;
        if (p.reading.isSeparator(c) or (sx.alternate_separator != null and c == sx.alternate_separator.?) or c == '*' or c == '?' or (c == '[' and sx.brackets != .none)) return false;
        if (sx.braces and (c == '{' or c == '}' or (c == ',' and p.depth > 0))) return false;
        if (sx.extglob and (c == ')' or c == '|' or (at + 1 < p.pattern.len and p.pattern[at + 1] == '(' and std.mem.findScalar(u8, "!+@", c) != null))) return false;
        return true;
    }
    fn normalLiterals(p: *Parser, start: usize) RunError!usize {
        var end = start;
        while (end < p.pattern.len and p.literalStart(end)) {
            const escaped = p.options.syntax.escape and p.pattern[end] == '\\';
            const at = end + @intFromBool(escaped);
            const u = p.decode(at);
            if (p.reading.isSeparator(u.code)) break;
            end = at + u.len;
        }
        if (end == start) {
            _ = try p.b.emit(.sep, 1);
            p.last = .sep;
            return start + 2;
        }
        var it: normal.Iterator = .init(p.pattern[start..end], p.options.syntax.escape);
        while (it.next()) |cp| try p.literal(cp, p.options.case == .ascii_git and p.pattern[start] == '\\');
        return end;
    }
    fn member(p: *Parser, comptime normalized: bool, at: usize) RunError!struct { code: Code, len: usize } {
        if (!normalized) {
            const u = p.decode(at);
            return .{ .code = u.code, .len = u.len };
        }
        var it: normal.Iterator = .init(p.pattern[at..], p.options.syntax.escape);
        const cp = it.next().?;
        const len = it.at;
        // All outputs belonging to the same canonical segment are one member.
        if (it.ordered) |o| {
            var rest = o;
            var starter = it.starter;
            const last: u8 = 0;
            while (rest.next()) |mark| {
                const cc = normal.combining(mark);
                if (starter) |st| if (last == 0 or last < cc) {
                    if (normal.compose(st, mark)) |joined| {
                        starter = joined;
                        continue;
                    }
                };
                return p.fail(.multi_scalar_member, at);
            }
        }
        return .{ .code = cp, .len = len };
    }

    fn decode(p: *const Parser, at: usize) unit.Unit {
        var u = unit.decode(p.reading.utf8, p.pattern, at);
        if (p.options.syntax.alternate_separator) |alt| if (u.code == alt and p.reading.separator != null) {
            u.code = p.reading.separator.?;
        };
        return u;
    }

    fn literal(p: *Parser, code: Code, escaped: bool) RunError!void {
        const canon = switch (p.options.case) {
            .sensitive => code,
            .ascii => unit.fold(code),
            .unicode => unicode.fold(code),
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
            if (sx.globstar_slash and last == .sep and after < p.pattern.len and p.reading.isSeparator(p.pattern[after])) {
                _ = try p.b.emit(.gstar, 0);
                p.b.uses_start = true;
                return;
            }
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
            p.b.nodes[split.raw()].arg = try program.operandAfter(split, 2);
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
    fn bracket(p: *Parser, comptime normalized: bool, i: usize) RunError!usize {
        const sx = p.options.syntax;
        const pattern = p.pattern;
        const b = p.b;
        if (b.class_len >= b.classes.len) return error.Full;
        var filler: class_mod.Filler = .init(b.ranges, aegis.int.cast(u32, b.range_len) catch return error.Full, p.options.case);
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
                const u = try p.member(normalized, at);
                filler.single(u.code);
                current = u.code;
                step = u.len;
            } else if (c == '-' and prev != 0 and at + 1 < pattern.len and pattern[at + 1] != ']') {
                at += 1;
                var high = try p.member(normalized, at);
                if (sx.escape and pattern[at] == '\\') {
                    at += 1;
                    if (at >= pattern.len) return p.unclosed(i);
                    high = try p.member(normalized, at);
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
                const u = try p.member(normalized, at);
                filler.single(u.code);
                current = u.code;
                step = u.len;
            }
            prev = current;
            at += step;
            if (at < pattern.len and pattern[at] == ']') break;
        }
        // Folding letter separators still permits their other case. The
        // consuming predicate excludes the raw separator independently.
        const separator = if (p.options.case == .unicode and p.reading.separator != null and (unit.isUpper(p.reading.separator.?) or unit.isLower(p.reading.separator.?))) null else p.reading.separator;
        const class = filler.finish(negated, separator);
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
        const head = b.node_len;
        if (p.options.syntax.single_brace_literal and p.pattern[i] == '{') _ = try b.emit(.lit, '{');
        const split = try b.emit(.split, 0);
        // safe: head precedes the successfully emitted split, bounded by max_arg.
        b.frames[p.depth] = .{ .split = split, .jumps = program.no_jump, .offset = .fromRaw(aegis.int.cast(u32, i) catch return error.Full), .head = .fromRaw(@intCast(head)) };
        p.depth += 1;
        p.last = .open;
    }

    fn alternative(p: *Parser) RunError!void {
        const b = p.b;
        const frame = &b.frames[p.depth - 1];
        if (frame.kind == .brace and p.options.syntax.single_brace_literal) b.nodes[frame.head.raw()] = .{ .op = .jump, .arg = try program.operandAfter(frame.head, 1) };
        const jump = try b.emit(.jump, try program.operand(frame.jumps));
        frame.jumps = jump;
        b.nodes[frame.split.raw()].arg = @intCast(b.node_len); // safe: emit bounds the current position
        frame.split = try b.emit(.split, 0);
        p.last = .open;
    }

    fn close(p: *Parser) RunError!void {
        const b = p.b;
        const frame = b.frames[p.depth - 1];
        if (frame.kind == .brace and frame.jumps == program.no_jump and p.options.syntax.single_brace_literal) _ = try b.emit(.lit, '}');
        // The last alternative needs no split: it falls through.
        b.nodes[frame.split.raw()] = .{ .op = .jump, .arg = try program.operandAfter(frame.split, 1) };
        var jump = frame.jumps;
        while (jump != program.no_jump) {
            const next = program.Position.fromRaw(b.nodes[jump.raw()].arg);
            b.nodes[jump.raw()].arg = @intCast(b.node_len); // safe: emit bounds the current position
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

// EditorConfig treats an unescaped slash inside a bracket literally, even
// when the bracket has no closing delimiter.
fn separatorBracket(text: []const u8, open: usize, sx: syntax.Syntax) ?usize {
    const sep = sx.separator orelse return null;
    var i = open + 1;
    var found = false;
    while (i < text.len) : (i += 1) {
        if (sx.escape and text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == ']') return if (found) i + 1 else null;
        if (text[i] == sep) found = true;
    }
    return if (found) text.len else null;
}

fn pairedBraces(text: []const u8, sx: syntax.Syntax) bool {
    var depth: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        if (sx.escape and text[at] == '\\' and at + 1 < text.len) {
            at += 1;
            continue;
        }
        if (text[at] == '{') depth += 1;
        if (text[at] == '}') {
            if (depth == 0) return false;
            depth -= 1;
        }
    }
    return depth == 0;
}
