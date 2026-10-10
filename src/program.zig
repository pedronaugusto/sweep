//! The automaton a pattern compiles to: a Thompson NFA over units whose
//! ordinary epsilon edges point forwards. Extglob repetition adds cycles;
//! visited contexts close each thread once per subject position.
//!
//! A thread carries one of three contexts, which say what the last pattern
//! item it passed was: a separator, something else, or a globstar whose
//! promise is still open (the next item must be a separator or the end).
//! Contexts make braces exact: a `**` or a leading `.` reached through an
//! alternative means what it would mean written out in full.
const std = @import("std");
const aegis = @import("aegis");
const normal = @import("normal.zig");
const unit = @import("unit.zig");
const unicode = @import("unicode.zig");
const syntax = @import("syntax.zig");
const class_mod = @import("class.zig");

pub const Class = class_mod.Class;
pub const Range = class_mod.Range;

/// What a node does.
pub const Op = enum(u4) {
    /// Consumes the unit whose canonical code is `arg`.
    lit,
    /// A literal `.` under `LeadingDot.explicit`, entered after a separator
    /// or at the start: may consume a leading dot. Goes on at `i + 2`.
    dot,
    /// The same literal entered after anything else: consumes a `.` that is
    /// not a leading dot. Never entered directly; `dot` redirects to it.
    dot_plain,
    /// The separator, written as itself (`arg` 0) or escaped (`arg` 1).
    /// Entered while a globstar's promise is open and unescaped, it
    /// consumes nothing and asserts the subject is at a component start.
    sep,
    /// `?`: any unit but the separator.
    any,
    /// A bracket: class `arg`.
    class,
    /// `*`: a loop over any unit but the separator, or over any unit when
    /// `arg` is 1. Exits to `i + 1`.
    star,
    /// A globstar: a loop over any unit, entered only after a separator or
    /// at the start, leaving its promise open. Exits to `i + 1`, or to
    /// `i + 2` when `arg` is 1.
    gstar,
    /// Epsilon to `i + 1` and to `arg`.
    split,
    /// Epsilon to `arg`.
    jump,
    /// The pattern matched: entry `arg >> 1`, directory-only when `arg & 1`.
    accept,
    /// Capture offset `arg`, used only by the on-demand tagged pass.
    save,
};

/// One node: an operation and its operand.
// aegis: safe-type-internals: docs/design.md#safety-boundaries; the packed operand holds several op-selected domains, validated by construction.
pub const Node = packed struct(u32) {
    op: Op,
    arg: u28,

    pub const max_arg = std.math.maxInt(u28);
};

/// A thread's context.
pub const Context = enum(u2) {
    /// The last item was a separator, or nothing was passed yet.
    sep,
    /// The last item was anything else.
    other,
    /// A globstar's promise is open.
    promise,
};

/// How a program reads its subject. Entries that read the same way can
/// share one automaton.
pub const Reading = struct {
    /// UTF-8 units rather than bytes.
    utf8: bool,
    nfc: bool = false,
    alternate_separator: ?u8 = null,
    /// The separator's unit code, or null in text mode.
    separator: ?unit.Code,
    /// Subject units are case folded before they are compared.
    fold: bool,
    /// Unicode simple folding rather than ASCII folding.
    unicode: bool,
    /// A leading `.` is hidden from wildcards.
    leading_dot: bool,
    /// Byte reader without separator spelling conversion.
    byte_input: bool = false,

    pub fn of(options: syntax.Options) Reading {
        const utf8 = options.syntax.unit == .utf8 or options.case == .unicode or options.normalization == .nfc;
        return .{
            .utf8 = utf8,
            .nfc = options.normalization == .nfc,
            .separator = if (options.syntax.separator) |s| unit.separatorCode(utf8, s) else null,
            .alternate_separator = options.syntax.alternate_separator,
            .fold = options.case != .sensitive,
            .unicode = options.case == .unicode,
            .leading_dot = options.syntax.leading_dot == .explicit,
            .byte_input = !utf8 and options.syntax.alternate_separator == null,
        };
    }

    pub fn eql(a: Reading, b: Reading) bool {
        return a.nfc == b.nfc and a.utf8 == b.utf8 and a.separator == b.separator and a.alternate_separator == b.alternate_separator and a.fold == b.fold and a.unicode == b.unicode and a.leading_dot == b.leading_dot;
    }

    /// Iterate the subject without allocating or changing its spelling.
    pub fn iterator(r: Reading, bytes: []const u8) Iterator {
        return .{ .bytes = bytes, .utf8 = r.utf8, .nfc = r.nfc, .alternate = r.alternate_separator, .separator = r.separator, .normal = if (r.nfc) .init(bytes, false) else undefined };
    }
    pub const Iterator = struct {
        bytes: []const u8,
        utf8: bool,
        nfc: bool,
        alternate: ?u8,
        separator: ?unit.Code,
        normal: normal.Iterator,
        at: usize = 0,
        pub fn next(it: *Iterator) ?unit.Code {
            if (it.nfc) {
                const cp = it.normal.next() orelse return null;
                it.at = it.normal.at;
                return it.code(cp);
            }
            if (it.at == it.bytes.len) return null;
            const u = unit.decode(it.utf8, it.bytes, it.at);
            it.at += u.len;
            return it.code(u.code);
        }
        fn code(it: *const Iterator, cp: unit.Code) unit.Code {
            return if (it.alternate != null and cp == it.alternate.? and it.separator != null) it.separator.? else cp;
        }
    };

    /// The code a subject unit is compared by.
    pub fn canonical(r: Reading, code: unit.Code) unit.Code {
        if (!r.fold) return code;
        return if (r.unicode) unicode.fold(code) else unit.fold(code);
    }

    pub fn isSeparator(r: Reading, code: unit.Code) bool {
        return if (r.separator) |s| code == s else false;
    }
};

/// A compiled automaton. Its slices belong to whoever built it.
pub const Program = struct {
    nodes: []const Node,
    classes: []const Class,
    ranges: []const Range,
    reading: Reading,
    /// Whether any node reads the component-start bit: a globstar's
    /// asserted separator, or a hidden leading dot.
    uses_start: bool,
    /// Repetition has a backward epsilon edge.
    cyclic: bool = false,

    /// States the step bound counts: every node in every context.
    pub fn states(p: Program) usize {
        return p.nodes.len * 3;
    }

    /// Whether node `k`, in the kernel, consumes `code` at a position whose
    /// previous unit is a separator (or that is the start) when `start`.
    pub fn consumes(p: Program, k: usize, code: unit.Code, start: bool) bool {
        return p.consumesCanonical(k, code, p.reading.canonical(code), start);
    }

    /// Tests a unit folded once for all threads. Raw codes retain separator
    /// and leading-dot meaning even when their canonical code aliases one.
    // aegis: measured-boundary: docs/design.md#safety-boundaries; the executor supplies a validated node index; all comparisons retain packed scalar form.
    pub fn consumesCanonical(p: Program, k: usize, code: unit.Code, canonical: unit.Code, start: bool) bool {
        const node = p.nodes[k];
        const r = p.reading;
        const hidden = r.leading_dot and start and code == '.';
        return switch (node.op) {
            .lit => canonical == node.arg,
            .dot => code == '.',
            .dot_plain => code == '.' and !hidden,
            .sep => r.isSeparator(code),
            .any => !r.isSeparator(code) and !hidden,
            .class => !r.isSeparator(code) and !hidden and p.classes[node.arg].contains(p.ranges, canonical),
            .star => (node.arg == 1 or !r.isSeparator(code)) and !hidden,
            .gstar => !hidden,
            .split, .jump, .save, .accept => false,
        };
    }
};

/// A position in the compiled program, distinct from source offsets and entry IDs.
pub const Position = aegis.id.Id(struct {}, u32);

/// One open brace group while parsing.
pub const Frame = struct {
    /// The split that opens the current alternative.
    split: Position,
    /// The last jump out of a finished alternative, chained through their
    /// operands; `no_jump` when none.
    jumps: Position,
    /// Where the `{` is, for a diagnostic.
    offset: aegis.units.Bytes(u32),
    /// First node and repetition rule of this group.
    head: Position = .fromRaw(0),
    kind: enum { brace, one, optional, zero_more, one_more } = .brace,
    capture: ?u32 = null,
};

pub const no_jump: Position = .fromRaw(Node.max_arg);

/// The operand that names `position`. Positions are issued below `Node.max_arg`, so only a position
/// made from outside the builder can fail here.
pub fn operand(position: Position) Builder.Full!u28 {
    return aegis.int.cast(u28, position.raw()) catch error.Full;
}

/// The operand that names the position `by` nodes on from `position`.
pub fn operandAfter(position: Position, by: u32) Builder.Full!u28 {
    return operand(position.advance(.fromRaw(by)) catch return error.Full);
}

/// Room a program is built into: fixed slices, filled from the front.
// aegis: measured-boundary: docs/design.md#safety-boundaries; slice cursors are validated at emit and remain raw within one construction pass.
pub const Builder = struct {
    nodes: []Node,
    classes: []Class,
    ranges: []Range,
    frames: []Frame,
    node_len: usize = 0,
    class_len: usize = 0,
    range_len: usize = 0,
    uses_start: bool = false,
    /// A repeated group emitted a backward epsilon edge.
    cyclic: bool = false,
    /// Emit capture tags only for a capture-cache build.
    capture: bool = false,
    capture_count: u32 = 0,

    pub const Full = error{Full};

    pub fn emit(b: *Builder, op: Op, arg: u28) Full!Position {
        if (b.node_len >= b.nodes.len or b.node_len >= Node.max_arg) return error.Full;
        b.nodes[b.node_len] = .{ .op = op, .arg = arg };
        b.node_len += 1;
        return .fromRaw(@intCast(b.node_len - 1)); // safe: bounded below max_arg before insertion
    }

    pub fn program(b: *const Builder, reading: Reading) Program {
        return .{
            .nodes = b.nodes[0..b.node_len],
            .classes = b.classes[0..b.class_len],
            .ranges = b.ranges[0..b.range_len],
            .reading = reading,
            .uses_start = b.uses_start,
            .cyclic = b.cyclic,
        };
    }
};

/// Upper bounds on what parsing `pattern` can need, for sizing a builder.
pub const Bounds = struct {
    pub const Nodes = aegis.units.Count(Node, usize);
    pub const Classes = aegis.units.Count(Class, usize);
    pub const Ranges = aegis.units.Count(Range, usize);
    pub const Frames = aegis.units.Count(Frame, usize);
    pub const Error = error{PatternTooLong};

    nodes: Nodes = .fromRaw(0),
    classes: Classes = .fromRaw(0),
    ranges: Ranges = .fromRaw(0),
    frames: Frames = .fromRaw(0),

    pub fn of(pattern: []const u8, options: syntax.Options) Error!Bounds {
        var brackets: usize = 0;
        var braces: usize = 0;
        // aegis: no-danger: docs/design.md#safety-boundaries; each counter is bounded by the source slice.
        for (pattern) |c| switch (c) {
            '[' => brackets += 1,
            '{', '(' => braces += 1,
            else => {},
        };
        const numeric = if (options.syntax.numeric_ranges) braces else 0;
        // Grammar expansion converts source bytes/groups to separate element domains.
        const plain = Nodes.fromRaw(pattern.len).mul(2) catch return error.PatternTooLong;
        const expanded = Nodes.fromRaw(numeric).mul(2048) catch return error.PatternTooLong;
        const nodes = (plain.add(.fromRaw(4)) catch return error.PatternTooLong).add(expanded) catch return error.PatternTooLong;
        const decimal = Classes.fromRaw(numeric).mul(45) catch return error.PatternTooLong;
        const classes = Classes.fromRaw(brackets).add(decimal) catch return error.PatternTooLong;
        const extra = Ranges.fromRaw(brackets).mul(if (options.case == .unicode) 1702 else 2) catch return error.PatternTooLong;
        const ranges = Ranges.fromRaw(pattern.len).add(extra) catch return error.PatternTooLong;
        return .{ .nodes = nodes, .classes = classes, .ranges = ranges, .frames = .fromRaw(braces) };
    }

    /// Whether a program within these bounds fits the room `limit` gives.
    pub fn fits(b: Bounds, limit: Bounds) bool {
        return b.nodes.compare(limit.nodes) != .gt and b.classes.compare(limit.classes) != .gt and b.ranges.compare(limit.ranges) != .gt and b.frames.compare(limit.frames) != .gt;
    }

    /// Adds an entry and its fork before allocating one combined automaton.
    pub fn append(total: *Bounds, entry: Bounds) Error!void {
        const nodes = (total.nodes.add(entry.nodes) catch return error.PatternTooLong).add(.fromRaw(1)) catch return error.PatternTooLong;
        const classes = total.classes.add(entry.classes) catch return error.PatternTooLong;
        const ranges = total.ranges.add(entry.ranges) catch return error.PatternTooLong;
        total.* = .{ .nodes = nodes, .classes = classes, .ranges = ranges, .frames = if (total.frames.compare(entry.frames) == .gt) total.frames else entry.frames };
    }

    /// A tagged program adds two capture instructions per source item.
    pub fn capture(b: *Bounds, source: []const u8) Error!void {
        const tags = (Nodes.fromRaw(source.len).mul(2) catch return error.PatternTooLong).add(.fromRaw(4)) catch return error.PatternTooLong;
        const nodes = b.nodes.add(tags) catch return error.PatternTooLong;
        b.nodes = nodes;
    }
};
