//! One-shot matching: parse into stack storage and simulate, no allocation.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program = @import("program.zig");
const parse = @import("parse.zig");
const nfa = @import("nfa.zig");

/// The longest pattern, in units, that `match` always takes.
pub const inline_units = 1024;

/// Brackets one `match` call holds; more is `error.PatternTooLong`.
pub const inline_classes = 64;

/// Ranges of non-ASCII members those brackets hold together.
pub const inline_ranges = 128;

/// Brace groups open at once in one `match` call.
pub const inline_depth = 256;

const max_nodes = 2 * inline_units + 4;
const max_words = nfa.words(max_nodes);

/// Everything one call keeps on the stack.
pub const Storage = struct {
    nodes: [max_nodes]program.Node,
    classes: [inline_classes]program.Class,
    ranges: [inline_ranges]program.Range,
    frames: [inline_depth]program.Frame,
    reach: [3][max_words]u64,
    kernel: [max_words]u64,
};

/// Whether `pattern` matches all of `subject`. Allocates nothing: it uses
/// about 16 KiB of stack (`@sizeOf(Storage)`). Takes patterns up to
/// `inline_units` units with up to `inline_classes` brackets; longer is
/// `error.PatternTooLong`, and a compiled `Pattern` takes it. Cost:
/// O(len(pattern) + len(subject) × states).
pub fn match(pattern: []const u8, subject: []const u8, options: syntax.Options) syntax.PatternError!bool {
    const utf8 = options.syntax.unit == .utf8;
    if (pattern.len > inline_units and unit.count(utf8, pattern) > inline_units) {
        if (options.diagnostics) |d| d.* = .{ .offset = 0, .reason = .too_long };
        return error.PatternTooLong;
    }
    var storage: Storage = undefined;
    var b: program.Builder = .{
        .nodes = &storage.nodes,
        .classes = &storage.classes,
        .ranges = &storage.ranges,
        .frames = &storage.frames,
    };
    try parse.parse(&b, pattern, options, .{});
    const p = b.program(.of(options));
    const n = nfa.words(p.nodes.len);
    var sim: nfa.Sim = .init(p, .{
        .reach = .{ storage.reach[0][0..n], storage.reach[1][0..n], storage.reach[2][0..n] },
        .kernel = storage.kernel[0..n],
    });
    return sim.run(subject);
}

test "the inline storage stays near 16 KiB" {
    try std.testing.expect(@sizeOf(Storage) <= 17 * 1024);
}
