//! One-shot matching: parse into stack storage and simulate, no allocation.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program = @import("program.zig");
const parse = @import("parse.zig");
const nfa = @import("nfa.zig");
const strategy = @import("strategy.zig");
const direct = @import("direct.zig");

/// The longest pattern, in units, that `match` always takes.
pub const inline_units = 1024;

/// Brackets one `match` call holds; more is `error.PatternTooLong`.
pub const inline_classes = 64;

/// What one call holds, for the direct executor to hand on what it does not.
pub const room: direct.Room = .{ .units = inline_units, .brackets = inline_classes };

/// Ranges of non-ASCII members those brackets hold together.
pub const inline_ranges = 128;

/// Brace groups open at once in one `match` call.
pub const inline_depth = 256;

/// Bytes of literal a call compares directly; longer literals go through
/// the automaton.
const inline_literal = 512;

const max_nodes = 2 * inline_units + 4;
const max_words = nfa.words(max_nodes);

/// Everything one call keeps on the stack.
pub const Storage = struct {
    nodes: [max_nodes]program.Node,
    classes: [inline_classes]program.Class,
    ranges: [inline_ranges]program.Range,
    frames: [inline_depth]program.Frame,
    reach: [3][max_words]u64,
    seen: [3][max_words]u64,
    kernel: [max_words]u64,
};

/// Whether `pattern` matches all of `subject`. Allocates nothing: a plain
/// pattern is read straight from its text, and any other is built on about
/// 24 KiB of stack (`@sizeOf(Storage)`). Takes patterns up to
/// `inline_units` units with up to `inline_classes` brackets, whichever
/// reader would take them; longer is `error.PatternTooLong`, and a compiled
/// `Pattern` takes it. Cost: O(len(pattern) + len(subject) × states).
/// Inline, so that options known at compile time choose the reader at
/// compile time.
pub inline fn match(pattern: []const u8, subject: []const u8, options: syntax.Options) syntax.PatternError!bool {
    // Inlined, the strings would be known at compile time wherever the
    // caller's are; they are read at run time.
    var p = pattern;
    var s = subject;
    _ = .{ &p, &s };
    // Plain patterns need no automaton, and most real ones are plain.
    return switch (direct.match(p, s, options, room)) {
        .no => false,
        .yes => true,
        .automaton => general(p, s, options),
    };
}

/// `match` for a pattern the direct executor hands on: one too long for
/// the call, or one the automaton reads.
noinline fn general(pattern: []const u8, subject: []const u8, options: syntax.Options) syntax.PatternError!bool {
    if (pattern.len > inline_units and tooLong(pattern, options)) return error.PatternTooLong;
    return automaton(pattern, subject, options);
}

/// Whether a pattern of more than `inline_units` bytes is more than that many
/// units, filling the diagnostic when it is.
noinline fn tooLong(pattern: []const u8, options: syntax.Options) bool {
    if (unit.count(options.syntax.unit == .utf8 or options.case == .unicode or options.normalization == .nfc, pattern) <= inline_units) return false;
    if (options.diagnostics) |d| d.* = .{ .offset = 0, .reason = .too_long };
    return true;
}

/// `match` by parse and simulation. Its own frame: the 24 KiB of storage is
/// set up only for a pattern the direct executor does not take.
noinline fn automaton(pattern: []const u8, subject: []const u8, options: syntax.Options) syntax.PatternError!bool {
    var storage: Storage = undefined;
    var b: program.Builder = .{
        .nodes = &storage.nodes,
        .classes = &storage.classes,
        .ranges = &storage.ranges,
        .frames = &storage.frames,
    };
    try parse.parse(&b, pattern, options, .{});
    const p = b.program(.of(options));
    // A literal strategy decides most real patterns with a few compares,
    // and the required prefix and suffix turn most others away early.
    const shape = strategy.recognise(p);
    var literal: [inline_literal]u8 = undefined;
    if (shape.strategy) |kind| {
        if (strategy.bytesInto(p, shape.first, shape.end, &literal)) |lit| {
            return (strategy.Strategy{ .kind = kind, .literal = lit }).matches(p.reading, subject);
        }
    } else if (strategy.bytesInto(p, 0, shape.head, literal[0 .. inline_literal / 2])) |head| {
        if (strategy.bytesInto(p, shape.tail_start, p.nodes.len - 1, literal[inline_literal / 2 ..])) |tail| {
            if (subject.len < head.len + tail.len) return false;
            if (!strategy.eql(p.reading, subject[0..head.len], head)) return false;
            if (!strategy.eql(p.reading, subject[subject.len - tail.len ..], tail)) return false;
        }
    }
    const n = nfa.words(p.nodes.len);
    var sim: nfa.Sim = .init(p, .{
        .reach = .{ storage.reach[0][0..n], storage.reach[1][0..n], storage.reach[2][0..n] },
        .kernel = storage.kernel[0..n],
        .seen = .{ storage.seen[0][0..n], storage.seen[1][0..n], storage.seen[2][0..n] },
    });
    return sim.run(subject);
}

test "the inline storage stays near 24 KiB" {
    try std.testing.expect(@sizeOf(Storage) <= 24 * 1024);
}
