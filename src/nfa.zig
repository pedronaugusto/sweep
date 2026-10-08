//! NFA simulation: the executor every other one falls back to.
//!
//! Threads live in bitsets over node indices, one per context while a set
//! is being closed and one kernel of consuming nodes between units. Every
//! ordinary epsilon edge points forwards, so closing is one sweep in index order.
//! Repeated extglobs use visited contexts only when a backward edge exists,
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

/// Four bitsets of `words(nodes)` words, plus three for cyclic programs.
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
        if (sim.program.cyclic) {
            for (sim.seen) |s| @memset(s, 0);
            sim.enter(true, 0, .sep);
            sim.close(true);
        } else {
            sim.enter(false, 0, .sep);
            sim.close(false);
        }
    }

    /// Consumes one unit. Returns whether any thread is left.
    pub fn step(sim: *Sim, code: Code) bool {
        return if (sim.program.cyclic) sim.advance(true, code) else sim.advance(false, code);
    }

    fn advance(sim: *Sim, comptime cyclic: bool, code: Code) bool {
        const p = sim.program;
        const at_start = sim.start;
        const canonical = p.reading.canonical(code);
        if (cyclic) for (sim.seen) |s| @memset(s, 0);
        var any = false;
        for (sim.kernel, 0..) |*word, w| {
            var bits = word.*;
            word.* = 0;
            while (bits != 0) : (bits &= bits - 1) {
                const k = w * 64 + @ctz(bits);
                if (!p.consumesCanonical(k, code, canonical, at_start)) continue;
                any = true;
                const node = p.nodes[k];
                switch (node.op) {
                    .lit, .any, .class, .dot_plain => sim.enter(cyclic, k + 1, .other),
                    .dot => sim.enter(cyclic, k + 2, .other),
                    .sep => sim.enter(cyclic, k + 1, .sep),
                    .star => sim.mark(cyclic, .other, k),
                    .gstar => sim.mark(cyclic, .promise, k),
                    .split, .jump, .save, .accept => unreachable,
                }
            }
        }
        sim.units += 1;
        sim.start = p.reading.isSeparator(code);
        if (!any) return false;
        sim.close(cyclic);
        return true;
    }

    /// Runs `subject` from the start and returns whether it matched.
    pub fn run(sim: *Sim, subject: []const u8) bool {
        sim.reset();
        const reading = sim.program.reading;
        if (reading.alternate_separator != null or (reading.nfc and !unit.isAscii(subject))) {
            var reader = reading.iterator(subject);
            while (reader.next()) |cp| if (!sim.step(cp)) return false;
        } else {
            var at: usize = 0;
            while (at < subject.len) {
                const u = unit.decode(reading.utf8, subject, at);
                if (!sim.step(u.code)) return false;
                at += u.len;
            }
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

    fn mark(sim: *Sim, comptime cyclic: bool, context: Context, k: usize) void {
        if (cyclic and sim.seen[@backingInt(context)][k / 64] >> @intCast(k % 64) & 1 != 0) return;
        const w = k / 64;
        sim.reach[@backingInt(context)][w] |= @as(u64, 1) << @intCast(k % 64);
        if (w < sim.low) sim.low = w;
    }

    /// A thread with `context` arrives at node `t`.
    fn enter(sim: *Sim, comptime cyclic: bool, t: usize, context: Context) void {
        const node = sim.program.nodes[t];
        switch (node.op) {
            .split, .jump, .save => sim.mark(cyclic, context, t),
            .gstar => if (context == .sep) sim.mark(cyclic, .promise, t),
            .star, .lit, .any, .class => if (context != .promise) sim.mark(cyclic, .other, t),
            .dot => switch (context) {
                .sep => sim.mark(cyclic, .other, t),
                .other => sim.mark(cyclic, .other, t + 1),
                .promise => {},
            },
            .dot_plain => unreachable,
            .sep => if (context == .promise and node.arg == 0) sim.mark(cyclic, .promise, t) else sim.mark(cyclic, .other, t),
            .accept => sim.mark(cyclic, .other, t),
        }
    }

    /// Closes the waiting threads into the kernel.
    fn close(sim: *Sim, comptime cyclic: bool) void {
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
            if (cyclic) {
                sim.seen[0][w] |= if (in_sep) mask else 0;
                sim.seen[1][w] |= if (in_other) mask else 0;
                sim.seen[2][w] |= if (in_promise) mask else 0;
            }
            r0[w] &= ~mask;
            r1[w] &= ~mask;
            r2[w] &= ~mask;
            sim.steps += @as(u64, @intFromBool(in_sep)) + @intFromBool(in_other) + @intFromBool(in_promise);
            if (cyclic) sim.low = w;
            const node = p.nodes[k];
            switch (node.op) {
                .split => {
                    if (in_sep) sim.fork(cyclic, k, node.arg, .sep);
                    if (in_other) sim.fork(cyclic, k, node.arg, .other);
                    if (in_promise) sim.fork(cyclic, k, node.arg, .promise);
                },
                .save => {
                    if (in_sep) sim.enter(cyclic, k + 1, .sep);
                    if (in_other) sim.enter(cyclic, k + 1, .other);
                    if (in_promise) sim.enter(cyclic, k + 1, .promise);
                },
                .jump => {
                    if (in_sep) sim.enter(cyclic, node.arg, .sep);
                    if (in_other) sim.enter(cyclic, node.arg, .other);
                    if (in_promise) sim.enter(cyclic, node.arg, .promise);
                },
                .sep => {
                    if (in_promise and sim.start) sim.enter(cyclic, k + 1, .sep);
                    if (in_other) sim.keep(k);
                },
                .star => {
                    sim.keep(k);
                    sim.enter(cyclic, k + 1, .other);
                },
                .gstar => {
                    sim.keep(k);
                    sim.enter(cyclic, if (node.arg == 1) k + 2 else k + 1, .promise);
                },
                .lit, .dot, .dot_plain, .any, .class, .accept => sim.keep(k),
            }
            if (cyclic) w = sim.low;
        }
        sim.low = r0.len;
        // The bound the design promises: each (node, context) at most once
        // per position.
        std.debug.assert(sim.steps <= (sim.units + 1) * p.states());
    }

    fn fork(sim: *Sim, comptime cyclic: bool, k: usize, target: usize, context: Context) void {
        sim.enter(cyclic, k + 1, context);
        sim.enter(cyclic, target, context);
    }

    fn keep(sim: *Sim, k: usize) void {
        sim.kernel[k / 64] |= @as(u64, 1) << @intCast(k % 64);
    }
};
