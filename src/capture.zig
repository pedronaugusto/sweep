//! Ordered Pike simulation for captures. A per-thread cache owns the tagged
//! program and scratch; ordinary matching carries no capture bookkeeping.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program_mod = @import("program.zig");
const parse = @import("parse.zig");
const Allocator = std.mem.Allocator;
const Context = program_mod.Context;

/// Byte offsets of a captured wildcard or group in the original subject.
pub const Capture = struct { start: usize, end: usize };
/// The caller's output has fewer slots than the pattern's capture count.
pub const MatchError = error{BufferTooSmall};
/// Allocating or constructing the tagged program failed.
pub const InitError = Allocator.Error || syntax.PatternError;

/// Per-thread tagged program and scratch. The pattern source is borrowed
/// and must outlive this cache. Scratch is O(states × captures), allocated
/// once, and every query visits a state at most once per subject position.
pub const Cache = struct {
    /// Private: tagged program and allocations.
    gpa: Allocator,
    source: []const u8,
    nodes: []program_mod.Node,
    classes: []program_mod.Class,
    ranges: []program_mod.Range,
    reading: program_mod.Reading,
    uses_start: bool,
    cyclic: bool = false,
    capture_count: usize,
    node_count: usize,
    class_count: usize,
    range_count: usize,
    current: Kernel,
    next: Kernel,
    frames: []u32,
    pending: []usize,
    temporary: []usize,
    seen: []bool,
    depth: usize = 0,
    offset: usize = 0,
    start: bool = true,

    const unset = std.math.maxInt(usize);
    const Kernel = struct { ids: []u32, histories: []usize, len: usize = 0 };

    /// Used by Pattern.captureCache after the source has been validated.
    pub fn init(gpa: Allocator, source: []const u8, options: syntax.Options) InitError!Cache {
        var bounds: program_mod.Bounds = .of(source, options);
        bounds.nodes += 2 * source.len + 4;
        const nodes = try gpa.alloc(program_mod.Node, bounds.nodes);
        errdefer gpa.free(nodes);
        const classes = try gpa.alloc(program_mod.Class, bounds.classes);
        errdefer gpa.free(classes);
        const ranges = try gpa.alloc(program_mod.Range, bounds.ranges);
        errdefer gpa.free(ranges);
        const frames = try gpa.alloc(program_mod.Frame, bounds.frames);
        defer gpa.free(frames);
        var b: program_mod.Builder = .{ .nodes = nodes, .classes = classes, .ranges = ranges, .frames = frames, .capture = true };
        try parse.parse(&b, source, options, .{});
        const states = b.node_len * 3;
        const slots = 2 * @as(usize, b.capture_count);
        const cur = try gpa.alloc(u32, states);
        errdefer gpa.free(cur);
        const next = try gpa.alloc(u32, states);
        errdefer gpa.free(next);
        const histories = std.math.mul(usize, states, slots) catch return error.OutOfMemory;
        const pending_count = std.math.mul(usize, histories, 2) catch return error.OutOfMemory;
        const history = try gpa.alloc(usize, histories);
        errdefer gpa.free(history);
        const other = try gpa.alloc(usize, histories);
        errdefer gpa.free(other);
        const stack = try gpa.alloc(u32, states * 2);
        errdefer gpa.free(stack);
        const pending = try gpa.alloc(usize, pending_count);
        errdefer gpa.free(pending);
        const temporary = try gpa.alloc(usize, slots);
        errdefer gpa.free(temporary);
        const seen = try gpa.alloc(bool, states);
        return .{ .gpa = gpa, .source = source, .nodes = nodes, .classes = classes, .ranges = ranges, .reading = .of(options), .uses_start = b.uses_start, .cyclic = b.cyclic, .capture_count = b.capture_count, .node_count = b.node_len, .class_count = b.class_len, .range_count = b.range_len, .current = .{ .ids = cur, .histories = history }, .next = .{ .ids = next, .histories = other }, .frames = stack, .pending = pending, .temporary = temporary, .seen = seen };
    }

    /// Frees the tagged program and scratch.
    pub fn deinit(c: *Cache) void {
        const gpa = c.gpa;
        gpa.free(c.nodes);
        gpa.free(c.classes);
        gpa.free(c.ranges);
        gpa.free(c.current.ids);
        gpa.free(c.next.ids);
        gpa.free(c.current.histories);
        gpa.free(c.next.histories);
        gpa.free(c.frames);
        gpa.free(c.pending);
        gpa.free(c.temporary);
        gpa.free(c.seen);
        c.* = undefined;
    }

    /// Capturable items in lexical opening order: stars, question marks,
    /// brackets, brace/range groups and extglob groups. Unselected items
    /// have a null capture; a matched empty item has equal byte offsets.
    pub fn count(c: *const Cache) usize {
        return c.capture_count;
    }

    /// Greedy stars and repetitions, first successful alternative wins.
    /// Output is written only on a match. No query allocates.
    pub fn matches(c: *Cache, subject: []const u8, out: []?Capture) MatchError!bool {
        if (out.len < c.capture_count) return error.BufferTooSmall;
        c.start = true;
        c.offset = 0;
        c.next.len = 0;
        c.depth = 0;
        @memset(c.seen, false);
        @memset(c.temporary, unset);
        c.close(0, .sep, false, c.temporary);
        std.mem.swap(Kernel, &c.current, &c.next);
        while (c.offset < subject.len) {
            const u = unit.decode(c.reading.utf8, subject, c.offset);
            const at_start = c.start;
            c.start = c.reading.isSeparator(u.code);
            c.offset += u.len;
            c.next.len = 0;
            @memset(c.seen, false);
            const p = c.program();
            for (c.current.ids[0..c.current.len]) |id| {
                const k = id / 3;
                if (!p.consumes(k, u.code, at_start)) continue;
                const node = p.nodes[k];
                const history = c.offsets(c.current, id);
                switch (node.op) {
                    .dot => c.close(k + 2, .other, false, history),
                    .sep => c.close(k + 1, .sep, false, history),
                    .star => c.close(k, .other, false, history),
                    .gstar => c.close(k, .promise, true, history),
                    .lit, .any, .class, .dot_plain => c.close(k + 1, .other, false, history),
                    else => unreachable,
                }
            }
            std.mem.swap(Kernel, &c.current, &c.next);
            if (c.current.len == 0) return false;
        }
        for (c.current.ids[0..c.current.len]) |id| if (c.nodes[id / 3].op == .accept) {
            const history = c.offsets(c.current, id);
            for (out[0..c.capture_count], 0..) |*capture, i| capture.* = if (history[2 * i] == unset or history[2 * i + 1] == unset) null else .{ .start = history[2 * i], .end = history[2 * i + 1] };
            return true;
        };
        return false;
    }

    fn program(c: *const Cache) program_mod.Program {
        return .{ .nodes = c.nodes[0..c.node_count], .classes = c.classes[0..c.class_count], .ranges = c.ranges[0..c.range_count], .reading = c.reading, .uses_start = c.uses_start, .cyclic = c.cyclic };
    }
    fn offsets(c: *const Cache, kernel: Kernel, id: usize) []usize {
        const slots = c.capture_count * 2;
        return kernel.histories[id * slots ..][0..slots];
    }
    fn push(c: *Cache, k: usize, context: Context, loop: bool, history: []const usize) void {
        // One spare bit says that a consuming globstar resumed its loop.
        const id = k * 3 + @as(usize, @backingInt(context));
        const slots = c.capture_count * 2;
        std.debug.assert(c.depth < c.frames.len);
        c.frames[c.depth] = @as(u32, @intCast(id)) | (if (loop) @as(u32, 1) << 31 else 0);
        @memcpy(c.pending[c.depth * slots ..][0..slots], history);
        c.depth += 1;
    }
    fn close(c: *Cache, k: usize, context: Context, loop: bool, history: []const usize) void {
        c.push(k, context, loop, history);
        while (c.depth > 0) {
            c.depth -= 1;
            const frame = c.frames[c.depth];
            const raw = frame & 0x7fff_ffff;
            var t: usize = raw / 3;
            var ctx: Context = @fromBackingInt(@intCast(raw % 3));
            var node = c.nodes[t];
            switch (node.op) {
                .gstar => if (frame >> 31 != 0 or ctx == .sep) {
                    ctx = .promise;
                } else continue,
                .star, .lit, .any, .class => if (ctx == .promise) {
                    continue;
                } else {
                    ctx = .other;
                },
                .dot => {
                    if (ctx == .promise) continue;
                    if (ctx == .other) {
                        t += 1;
                        node = c.nodes[t];
                    }
                    ctx = .other;
                },
                .sep => if (ctx != .promise or node.arg != 0) {
                    ctx = .other;
                },
                .accept => ctx = .other,
                else => {},
            }
            const id = t * 3 + @as(usize, @backingInt(ctx));
            if (c.seen[id]) continue;
            c.seen[id] = true;
            const slots = c.capture_count * 2;
            @memcpy(c.temporary, c.pending[c.depth * slots ..][0..slots]);
            switch (node.op) {
                .save => {
                    c.temporary[node.arg] = c.offset;
                    c.push(t + 1, ctx, false, c.temporary);
                },
                .jump => c.push(node.arg, ctx, false, c.temporary),
                .split => {
                    if (node.arg <= t) {
                        c.push(t + 1, ctx, false, c.temporary);
                        c.push(node.arg, ctx, false, c.temporary);
                    } else {
                        c.push(node.arg, ctx, false, c.temporary);
                        c.push(t + 1, ctx, false, c.temporary);
                    }
                },
                .sep => if (ctx == .promise) {
                    if (c.start) c.push(t + 1, .sep, false, c.temporary);
                } else c.keep(id),
                .star, .gstar => {
                    c.keep(id);
                    c.push(if (node.op == .gstar and node.arg == 1) t + 2 else t + 1, if (node.op == .gstar) .promise else .other, false, c.temporary);
                },
                else => c.keep(id),
            }
        }
    }
    fn keep(c: *Cache, id: usize) void {
        c.next.ids[c.next.len] = @intCast(id);
        c.next.len += 1;
        @memcpy(c.offsets(c.next, id), c.temporary);
    }
};
