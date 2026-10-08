//! NFA simulation: the executor every other one falls back to.
//!
//! Threads live in bitsets over node indices, one per context while a set
//! is being closed and one kernel of consuming nodes between units. Every
//! epsilon edge points forwards, so closing is one sweep in index order,
//! each (node, context) taken at most once per position: O(m) per unit and
//! O(n·m) per subject, asserted in safe builds.
const std = @import("std");
const unit = @import("unit.zig");
const program_mod = @import("program.zig");

const Program = program_mod.Program;
const Context = program_mod.Context;
const Code = unit.Code;

/// Words of a bitset over `nodes` nodes.
pub fn words(nodes: usize) usize {
    return (nodes + 63) / 64;
}

/// The scratch one simulation needs: four bitsets of `words(nodes)` words.
pub const Scratch = struct {
    /// Threads waiting to be closed, by context.
    reach: [3][]u64,
    /// Consuming threads (and accepts) after closing.
    kernel: []u64,
    seen: [3][]u64,
};

/// A simulation in progress over one program.
pub const Sim = struct {
    program: Program,
    reach: [3][]u64,
    kernel: []u64,
    seen: [3][]u64,
    /// The lowest word of `reach` that may hold a bit.
    low: usize = 0,
    /// (node, context) states closed so far.
    steps: u64 = 0,
    /// Units consumed so far.
    units: u64 = 0,
    /// Whether the last unit was a separator, or nothing was consumed.
    start: bool = true,

    pub fn init(program: Program, scratch: Scratch) Sim {
        return .{ .program = program, .reach = scratch.reach, .kernel = scratch.kernel, .seen = scratch.seen };
    }

    /// Starts over at position 0.
    pub fn reset(sim: *Sim) void {
        for (sim.reach) |r| @memset(r, 0);
        @memset(sim.kernel, 0);
        sim.low = sim.kernel.len;
        sim.steps = 0;
        sim.units = 0;
        sim.start = true;
        for (sim.seen) |s| @memset(s, 0);
        sim.enter(0, .sep);
        sim.close();
    }

    /// Consumes one unit. Returns whether any thread is left.
    pub fn step(sim: *Sim, code: Code) bool {
        const p = sim.program;
        const at_start = sim.start;
        for (sim.seen) |s| @memset(s, 0);
        var any = false;
        for (sim.kernel, 0..) |*word, w| {
            var bits = word.*;
            word.* = 0;
            while (bits != 0) : (bits &= bits - 1) {
                const k = w * 64 + @ctz(bits);
                if (!p.consumes(k, code, at_start)) continue;
                any = true;
                const node = p.nodes[k];
                switch (node.op) {
                    .lit, .any, .class, .dot_plain => sim.enter(k + 1, .other),
                    .dot => sim.enter(k + 2, .other),
                    .sep => sim.enter(k + 1, .sep),
                    .star => sim.mark(.other, k),
                    .gstar => sim.mark(.promise, k),
                    .split, .jump, .save, .accept => unreachable,
                }
            }
        }
        sim.units += 1;
        sim.start = p.reading.isSeparator(code);
        if (!any) return false;
        sim.close();
        return true;
    }

    /// Runs `subject` from the start and returns whether it matched.
    pub fn run(sim: *Sim, subject: []const u8) bool {
        sim.reset();
        const utf8 = sim.program.reading.utf8;
        var at: usize = 0;
        while (at < subject.len) {
            const u = unit.decode(utf8, subject, at);
            if (!sim.step(u.code)) return false;
            at += u.len;
        }
        return sim.accepting();
    }

    /// Whether some thread stands at an accept node.
    pub fn accepting(sim: *const Sim) bool {
        var it = sim.threads();
        while (it.next()) |k| if (sim.program.nodes[k].op == .accept) return true;
        return false;
    }

    /// Whether node `k` is in the kernel.
    pub fn has(sim: *const Sim, k: usize) bool {
        return sim.kernel[k / 64] >> @intCast(k % 64) & 1 != 0;
    }

    /// The kernel's nodes in ascending order.
    pub fn threads(sim: *const Sim) Threads {
        return .{ .kernel = sim.kernel };
    }

    pub const Threads = struct {
        kernel: []const u64,
        word: usize = 0,
        bits: u64 = 0,
        primed: bool = false,

        pub fn next(it: *Threads) ?usize {
            if (!it.primed) {
                it.primed = true;
                if (it.kernel.len == 0) return null;
                it.bits = it.kernel[0];
            }
            while (it.bits == 0) {
                it.word += 1;
                if (it.word >= it.kernel.len) return null;
                it.bits = it.kernel[it.word];
            }
            const k = it.word * 64 + @ctz(it.bits);
            it.bits &= it.bits - 1;
            return k;
        }
    };

    fn mark(sim: *Sim, context: Context, k: usize) void {
        if (sim.seen[@backingInt(context)][k / 64] >> @intCast(k % 64) & 1 != 0) return;
        const w = k / 64;
        sim.reach[@backingInt(context)][w] |= @as(u64, 1) << @intCast(k % 64);
        if (w < sim.low) sim.low = w;
    }

    /// A thread with `context` arrives at node `t`.
    fn enter(sim: *Sim, t: usize, context: Context) void {
        const node = sim.program.nodes[t];
        switch (node.op) {
            .split, .jump, .save => sim.mark(context, t),
            .gstar => if (context == .sep) sim.mark(.promise, t),
            .star, .lit, .any, .class => if (context != .promise) sim.mark(.other, t),
            .dot => switch (context) {
                .sep => sim.mark(.other, t),
                .other => sim.mark(.other, t + 1),
                .promise => {},
            },
            .dot_plain => unreachable,
            .sep => if (context == .promise and node.arg == 0) sim.mark(.promise, t) else sim.mark(.other, t),
            .accept => sim.mark(.other, t),
        }
    }

    /// Closes the waiting threads into the kernel.
    fn close(sim: *Sim) void {
        const p = sim.program;
        const r0 = sim.reach[0];
        const r1 = sim.reach[1];
        const r2 = sim.reach[2];
        var w = sim.low;
        while (w < r0.len) {
            const bits = r0[w] | r1[w] | r2[w];
            if (bits == 0) {
                w += 1;
                continue;
            }
            const bit: u6 = @intCast(@ctz(bits));
            const mask = @as(u64, 1) << bit;
            const k = w * 64 + bit;
            const in_sep = r0[w] & mask != 0;
            const in_other = r1[w] & mask != 0;
            const in_promise = r2[w] & mask != 0;
            sim.seen[0][w] |= if (in_sep) mask else 0;
            sim.seen[1][w] |= if (in_other) mask else 0;
            sim.seen[2][w] |= if (in_promise) mask else 0;
            r0[w] &= ~mask;
            r1[w] &= ~mask;
            r2[w] &= ~mask;
            sim.steps += @as(u64, @intFromBool(in_sep)) + @intFromBool(in_other) + @intFromBool(in_promise);
            sim.low = w;
            const node = p.nodes[k];
            switch (node.op) {
                .split => {
                    if (in_sep) sim.fork(k, node.arg, .sep);
                    if (in_other) sim.fork(k, node.arg, .other);
                    if (in_promise) sim.fork(k, node.arg, .promise);
                },
                .save => {
                    if (in_sep) sim.enter(k + 1, .sep);
                    if (in_other) sim.enter(k + 1, .other);
                    if (in_promise) sim.enter(k + 1, .promise);
                },
                .jump => {
                    if (in_sep) sim.enter(node.arg, .sep);
                    if (in_other) sim.enter(node.arg, .other);
                    if (in_promise) sim.enter(node.arg, .promise);
                },
                .sep => {
                    if (in_promise and sim.start) sim.enter(k + 1, .sep);
                    if (in_other) sim.keep(k);
                },
                .star => {
                    sim.keep(k);
                    sim.enter(k + 1, .other);
                },
                .gstar => {
                    sim.keep(k);
                    sim.enter(if (node.arg == 1) k + 2 else k + 1, .promise);
                },
                .lit, .dot, .dot_plain, .any, .class, .accept => sim.keep(k),
            }
            w = sim.low;
        }
        sim.low = r0.len;
        // The bound the design promises: each (node, context) at most once
        // per position.
        std.debug.assert(sim.steps <= (sim.units + 1) * p.states());
    }

    fn fork(sim: *Sim, k: usize, target: usize, context: Context) void {
        sim.enter(k + 1, context);
        sim.enter(target, context);
    }

    fn keep(sim: *Sim, k: usize) void {
        sim.kernel[k / 64] |= @as(u64, 1) << @intCast(k % 64);
    }
};
