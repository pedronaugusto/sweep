//! The time bound, as a property: on every adversarial family the closed
//! (node, context) states stay within (n + 1) × states, at sizes where a
//! backtracker would not finish.
const std = @import("std");
const sweep = @import("../sweep.zig");
const program = @import("../program.zig");
const parse = @import("../parse.zig");
const nfa = @import("../nfa.zig");

const gpa = std.testing.allocator;

/// A program on the heap, for patterns past the one-shot limit.
const Owned = struct {
    b: program.Builder,
    reach: [3][]u64,
    kernel: []u64,
    options: sweep.Options,

    fn init(pattern: []const u8, options: sweep.Options) !Owned {
        const bounds: program.Bounds = .of(pattern);
        var b: program.Builder = .{
            .nodes = try gpa.alloc(program.Node, bounds.nodes),
            .classes = try gpa.alloc(program.Class, bounds.classes),
            .ranges = try gpa.alloc(program.Range, bounds.ranges),
            .frames = try gpa.alloc(program.Frame, bounds.frames),
        };
        try parse.parse(&b, pattern, options, .{});
        const words = nfa.words(b.node_len);
        var owned: Owned = .{ .b = b, .reach = undefined, .kernel = try gpa.alloc(u64, words), .options = options };
        for (&owned.reach) |*r| r.* = try gpa.alloc(u64, words);
        return owned;
    }

    fn deinit(o: *Owned) void {
        gpa.free(o.b.nodes);
        gpa.free(o.b.classes);
        gpa.free(o.b.ranges);
        gpa.free(o.b.frames);
        gpa.free(o.kernel);
        for (o.reach) |r| gpa.free(r);
        o.* = undefined;
    }

    /// Runs `subject` and checks the bound outside the assertion too.
    fn run(o: *Owned, subject: []const u8) !bool {
        const p = o.b.program(.of(o.options));
        var sim: nfa.Sim = .init(p, .{ .reach = o.reach, .kernel = o.kernel });
        const matched = sim.run(subject);
        try std.testing.expect(sim.steps <= (sim.units + 1) * p.states());
        return matched;
    }
};

fn repeat(piece: []const u8, times: usize, tail: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..times) |_| try out.appendSlice(gpa, piece);
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

fn family(piece: []const u8, times: usize, tail: []const u8, subject: []const u8, options: sweep.Options, want: bool) !void {
    const pattern = try repeat(piece, times, tail);
    defer gpa.free(pattern);
    var owned: Owned = try .init(pattern, options);
    defer owned.deinit();
    try std.testing.expectEqual(want, try owned.run(subject));
}

test "up to 32 stars before an absent literal" {
    const a4096 = try repeat("a", 4096, "");
    defer gpa.free(a4096);
    for ([_]usize{ 1, 8, 32 }) |k| {
        try family("*a", k, "b", a4096, .{}, false);
        try family("*a", k, "b", a4096, .{ .syntax = .git_text }, false);
        try family("*", k, "b", a4096, .{}, false);
    }
}

test "globstar chains, adjacent or not, over deep paths" {
    const deep = try repeat("x/", 60, "y");
    defer gpa.free(deep);
    try family("**/", 32, "z", deep, .{}, false);
    try family("**/", 32, "y", deep, .{}, true);
    try family("*/**/", 30, "z", deep, .{}, false);
    try family("**/x*/", 12, "z", deep, .{}, false);
    try family("**/a/", 16, "z", deep, .{}, false);
}

test "lookout's stall shapes" {
    const deep = try repeat("a", 4000, "/c");
    defer gpa.free(deep);
    try family("**a", 20, "**b", deep, .{}, false);
    try family("**a*a*a*a*a*a*/", 1, "b", deep, .{}, false);
    try family("*a", 8, "*/b", deep, .{ .syntax = .{ .globstar = .anywhere } }, false);
}

test "brace bombs are linear" {
    const subject = try repeat("ab", 2048, "");
    defer gpa.free(subject);
    try family("{a,b}", 20, "", subject[0..20], .{ .syntax = .glob }, true);
    try family("{a,b}", 20, "*", subject, .{ .syntax = .glob }, true);
    try family("{a,ab,b}", 200, "c", subject, .{ .syntax = .glob }, false);
    // Braces nested 200 deep.
    const open = try repeat("{a,", 200, "b");
    defer gpa.free(open);
    const nested = try repeat("}", 200, "");
    defer gpa.free(nested);
    const pattern = try std.mem.concat(gpa, u8, &.{ open, nested });
    defer gpa.free(pattern);
    var owned: Owned = try .init(pattern, .{ .syntax = .glob });
    defer owned.deinit();
    try std.testing.expect(try owned.run("b"));
    try std.testing.expect(try owned.run("a"));
    try std.testing.expect(!try owned.run(subject));
}

test "a 4096-member bracket against a 4096-unit subject" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(gpa);
    try pattern.append(gpa, '[');
    for (0..4096) |i| try pattern.append(gpa, "abcdefgh"[i % 8]);
    try pattern.appendSlice(gpa, "]*");
    const subject = try repeat("h", 4096, "");
    defer gpa.free(subject);
    var owned: Owned = try .init(pattern.items, .{});
    defer owned.deinit();
    try std.testing.expect(try owned.run(subject));
}

test "a 4096-unit pattern against a 4096-unit subject" {
    const pattern = try repeat("*a?", 1365, "b");
    defer gpa.free(pattern);
    const subject = try repeat("a", 4096, "");
    defer gpa.free(subject);
    var owned: Owned = try .init(pattern, .{});
    defer owned.deinit();
    try std.testing.expect(!try owned.run(subject));
}
