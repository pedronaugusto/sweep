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
    /// The separator's unit code, or null in text mode.
    separator: ?unit.Code,
    /// Subject units are case folded before they are compared.
    fold: bool,
    /// Unicode simple folding rather than ASCII folding.
    unicode: bool,
    /// A leading `.` is hidden from wildcards.
    leading_dot: bool,

    pub fn of(options: syntax.Options) Reading {
        const utf8 = options.syntax.unit == .utf8 or options.case == .unicode;
        return .{
            .utf8 = utf8,
            .separator = if (options.syntax.separator) |s| unit.separatorCode(utf8, s) else null,
            .fold = options.case != .sensitive,
            .unicode = options.case == .unicode,
            .leading_dot = options.syntax.leading_dot == .explicit,
        };
    }

    pub fn eql(a: Reading, b: Reading) bool {
        return a.utf8 == b.utf8 and a.separator == b.separator and a.fold == b.fold and a.unicode == b.unicode and a.leading_dot == b.leading_dot;
    }

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

    /// States the step bound counts: every node in every context.
    pub fn states(p: Program) usize {
        return p.nodes.len * 3;
    }

    /// Whether node `k`, in the kernel, consumes `code` at a position whose
    /// previous unit is a separator (or that is the start) when `start`.
    pub fn consumes(p: Program, k: usize, code: unit.Code, start: bool) bool {
        const node = p.nodes[k];
        const r = p.reading;
        const hidden = r.leading_dot and start and code == '.';
        return switch (node.op) {
            .lit => r.canonical(code) == node.arg,
            .dot => code == '.',
            .dot_plain => code == '.' and !hidden,
            .sep => r.isSeparator(code),
            .any => !r.isSeparator(code) and !hidden,
            .class => !r.isSeparator(code) and !hidden and p.classes[node.arg].contains(p.ranges, r.canonical(code)),
            .star => (node.arg == 1 or !r.isSeparator(code)) and !hidden,
            .gstar => !hidden,
            .split, .jump, .save, .accept => false,
        };
    }
};

/// One open brace group while parsing.
pub const Frame = struct {
    /// The split that opens the current alternative.
    split: u32,
    /// The last jump out of a finished alternative, chained through their
    /// operands; `no_jump` when none.
    jumps: u32,
    /// Where the `{` is, for a diagnostic.
    offset: u32,
    /// First node and repetition rule of this group.
    head: u32 = 0,
    kind: enum { brace, one, optional, zero_more, one_more } = .brace,
    capture: ?u32 = null,
};

pub const no_jump: u32 = Node.max_arg;

/// Room a program is built into: fixed slices, filled from the front.
pub const Builder = struct {
    nodes: []Node,
    classes: []Class,
    ranges: []Range,
    frames: []Frame,
    node_len: usize = 0,
    class_len: usize = 0,
    range_len: usize = 0,
    uses_start: bool = false,
    /// Emit capture tags only for a capture-cache build.
    capture: bool = false,
    capture_count: u32 = 0,

    pub const Full = error{Full};

    pub fn emit(b: *Builder, op: Op, arg: u28) Full!u32 {
        if (b.node_len >= b.nodes.len or b.node_len >= Node.max_arg) return error.Full;
        b.nodes[b.node_len] = .{ .op = op, .arg = arg };
        b.node_len += 1;
        return @intCast(b.node_len - 1);
    }

    pub fn program(b: *const Builder, reading: Reading) Program {
        return .{
            .nodes = b.nodes[0..b.node_len],
            .classes = b.classes[0..b.class_len],
            .ranges = b.ranges[0..b.range_len],
            .reading = reading,
            .uses_start = b.uses_start,
        };
    }
};

/// Upper bounds on what parsing `pattern` can need, for sizing a builder.
pub const Bounds = struct {
    nodes: usize,
    classes: usize,
    ranges: usize,
    frames: usize,

    pub fn of(pattern: []const u8, options: syntax.Options) Bounds {
        const sx = options.syntax;
        var brackets: usize = 0;
        var braces: usize = 0;
        for (pattern) |c| switch (c) {
            '[' => brackets += 1,
            '{', '(' => braces += 1,
            else => {},
        };
        const numeric = if (sx.numeric_ranges) braces else 0;
        return .{
            // Two nodes a unit at most (`,` and a hidden-dot `.`), the
            // `anywhere` prefix and the accept.
            .nodes = 2 * pattern.len + 4 + numeric * 2048,
            // The interval compiler interns the 45 non-singleton digit ranges.
            .classes = brackets + numeric * 45,
            // A member adds at most one range, a negation one more, and
            // taking out the separator one more.
            // Only source brackets need Unicode images; generated decimal
            // classes contain ASCII digits, whose fold is the identity.
            .ranges = pattern.len + 2 * brackets + (if (options.case == .unicode) brackets * 1700 else 0),
            .frames = braces,
        };
    }
};
