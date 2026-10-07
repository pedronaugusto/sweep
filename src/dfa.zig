//! What the DFAs share: unit classes, which threads can still match, and
//! the step from one closed set of threads to the next.
//!
//! A DFA state is a closed kernel (a sorted list of node indices) plus the
//! component-start bit, since a hidden leading dot and a globstar's
//! separator both look one unit back. Threads that can no longer reach an
//! accept are dropped, so the empty kernel is the one dead state.
const std = @import("std");
const unit = @import("unit.zig");
const program_mod = @import("program.zig");
const nfa = @import("nfa.zig");

const Allocator = std.mem.Allocator;
const Program = program_mod.Program;
const Code = unit.Code;

/// Unit classes: codes no node of the program tells apart share a class,
/// and a DFA keeps one transition per class.
pub const Classes = struct {
    /// The class of each code below 256.
    low: [256]u16,
    /// Codes from 256 on: the start of each run of codes in one class,
    /// ascending, and the run's class.
    starts: []u32,
    ids: []u16,
    /// One code of each class.
    reps: []Code,

    pub fn count(c: *const Classes) usize {
        return c.reps.len;
    }

    pub fn of(c: *const Classes, code: Code) u16 {
        if (code < 256) return c.low[code];
        // The last run starting at or below `code`.
        var lo: usize = 0;
        var hi: usize = c.starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (c.starts[mid] <= code) lo = mid + 1 else hi = mid;
        }
        return c.ids[lo - 1];
    }

    pub fn deinit(c: *Classes, gpa: Allocator) void {
        gpa.free(c.starts);
        gpa.free(c.ids);
        gpa.free(c.reps);
        c.* = undefined;
    }

    /// The classes of `p`.
    pub fn init(gpa: Allocator, p: Program) Allocator.Error!Classes {
        // Runs above 255 begin where any class range, literal or the
        // separator begins or ends.
        var bounds: std.ArrayList(u32) = .empty;
        defer bounds.deinit(gpa);
        try bounds.append(gpa, 256);
        if (p.reading.utf8) {
            for (p.ranges) |r| try bounds.appendSlice(gpa, &.{ r.lo, r.hi + 1 });
            for (p.nodes) |node| if (node.op == .lit and node.arg >= 256) try bounds.appendSlice(gpa, &.{ node.arg, node.arg + 1 });
            if (p.reading.separator) |s| if (s >= 256) try bounds.appendSlice(gpa, &.{ s, s + 1 });
        }
        std.mem.sortUnstable(u32, bounds.items, {}, std.sort.asc(u32));
        var runs: usize = 0;
        for (bounds.items) |b| {
            if (b > class_max) continue;
            if (runs > 0 and bounds.items[runs - 1] == b) continue;
            bounds.items[runs] = b;
            runs += 1;
        }
        bounds.items.len = if (p.reading.utf8) runs else 0;
        // Elements: the 256 low codes, then one per run.
        const elements = 256 + bounds.items.len;
        const reps = try gpa.alloc(Code, elements);
        defer gpa.free(reps);
        for (reps[0..256], 0..) |*r, i| r.* = @intCast(i);
        for (reps[256..], bounds.items) |*r, b| r.* = @intCast(b);
        const ids = try gpa.alloc(u16, elements);
        defer gpa.free(ids);
        @memset(ids, 0);
        var classes: u16 = 1;
        var refiner: Refiner = try .init(gpa, elements);
        defer refiner.deinit(gpa);
        // Every distinction a node makes.
        classes = refiner.split(ids, classes, reps, p, .separator, 0);
        classes = refiner.split(ids, classes, reps, p, .dot, 0);
        for (p.nodes, 0..) |node, k| switch (node.op) {
            .lit => classes = refiner.split(ids, classes, reps, p, .literal, k),
            .class => classes = refiner.split(ids, classes, reps, p, .class, k),
            else => {},
        };
        var out: Classes = .{ .low = undefined, .starts = &.{}, .ids = &.{}, .reps = &.{} };
        @memcpy(&out.low, ids[0..256]);
        out.starts = try gpa.dupe(u32, bounds.items);
        errdefer gpa.free(out.starts);
        out.ids = try gpa.dupe(u16, ids[256..]);
        errdefer gpa.free(out.ids);
        out.reps = try gpa.alloc(Code, classes);
        var i = elements;
        while (i > 0) {
            i -= 1;
            out.reps[ids[i]] = reps[i];
        }
        return out;
    }
};

const class_max: u32 = @import("class.zig").max_code;

const Predicate = enum { separator, dot, literal, class };

/// Partition refinement: each predicate splits every class in two.
const Refiner = struct {
    map: []u16,

    fn init(gpa: Allocator, elements: usize) Allocator.Error!Refiner {
        return .{ .map = try gpa.alloc(u16, 2 * elements) };
    }

    fn deinit(r: *Refiner, gpa: Allocator) void {
        gpa.free(r.map);
        r.* = undefined;
    }

    fn split(r: *Refiner, ids: []u16, classes: u16, reps: []const Code, p: Program, predicate: Predicate, k: usize) u16 {
        const none = std.math.maxInt(u16);
        @memset(r.map[0 .. 2 * @as(usize, classes)], none);
        var next: u16 = 0;
        for (ids, reps) |*id, code| {
            const in = holds(p, predicate, k, code);
            const slot = &r.map[2 * @as(usize, id.*) + @intFromBool(in)];
            if (slot.* == none) {
                slot.* = next;
                next += 1;
            }
            id.* = slot.*;
        }
        return next;
    }

    fn holds(p: Program, predicate: Predicate, k: usize, code: Code) bool {
        const r = p.reading;
        return switch (predicate) {
            .separator => r.isSeparator(code),
            .dot => code == '.',
            .literal => r.canonical(code) == p.nodes[k].arg,
            .class => p.classes[p.nodes[k].arg].contains(p.ranges, r.canonical(code)),
        };
    }
};

/// Whether each kernel node can still reach an accept: bit 0 at a position
/// that is not a component start, bit 1 at one.
pub fn liveness(gpa: Allocator, p: Program) Allocator.Error![]u2 {
    const n = p.nodes.len;
    const kernel = try gpa.alloc(u2, n);
    errdefer gpa.free(kernel);
    // What entering node t with a context at a position gives: 3 contexts
    // by 2 start bits.
    const entered = try gpa.alloc(u6, n + 1);
    defer gpa.free(entered);
    @memset(kernel, 0);
    entered[n] = 0;
    var i = n;
    while (i > 0) {
        i -= 1;
        kernel[i] = kernelLive(p, entered, i);
        entered[i] = enterLive(p, kernel, entered, i);
    }
    return kernel;
}

fn bitOf(set: u6, context: program_mod.Context, start: bool) bool {
    const shift: u3 = @intCast(@as(u3, @backingInt(context)) * 2 + @intFromBool(start));
    return set >> shift & 1 != 0;
}

fn enterLive(p: Program, kernel: []const u2, entered: []const u6, t: usize) u6 {
    var out: u6 = 0;
    inline for ([_]program_mod.Context{ .sep, .other, .promise }) |context| {
        inline for (.{ false, true }) |start| {
            if (enterOne(p, kernel, entered, t, context, start)) {
                out |= @as(u6, 1) << (@as(u3, @backingInt(context)) * 2 + @intFromBool(start));
            }
        }
    }
    return out;
}

fn kernelBit(kernel: []const u2, k: usize, start: bool) bool {
    return kernel[k] >> @intFromBool(start) & 1 != 0;
}

fn enterOne(p: Program, kernel: []const u2, entered: []const u6, t: usize, context: program_mod.Context, start: bool) bool {
    const node = p.nodes[t];
    return switch (node.op) {
        .split => bitOf(entered[t + 1], context, start) or bitOf(entered[node.arg], context, start),
        .jump => bitOf(entered[node.arg], context, start),
        .gstar => context == .sep and (bitOf(entered[exitOf(node, t)], .promise, start) or kernelBit(kernel, t, start)),
        .star => context != .promise and (bitOf(entered[t + 1], .other, start) or kernelBit(kernel, t, start)),
        .lit, .any, .class => context != .promise and kernelBit(kernel, t, start),
        .dot => switch (context) {
            .sep => kernelBit(kernel, t, start),
            .other => kernelBit(kernel, t + 1, start),
            .promise => false,
        },
        .dot_plain => false,
        .sep => if (context == .promise and node.arg == 0)
            start and bitOf(entered[t + 1], .sep, true)
        else
            kernelBit(kernel, t, start),
        .accept => true,
    };
}

fn exitOf(node: program_mod.Node, t: usize) usize {
    return if (node.arg == 1) t + 2 else t + 1;
}

/// Kernel node `k`'s liveness, from what its targets give.
fn kernelLive(p: Program, entered: []const u6, k: usize) u2 {
    const node = p.nodes[k];
    var out: u2 = 0;
    switch (node.op) {
        .star, .gstar => {
            // A loop: consuming lands on the loop again, which may exit.
            const exit_context: program_mod.Context = if (node.op == .gstar) .promise else .other;
            const exit = if (node.op == .gstar) exitOf(node, k) else k + 1;
            var live: [2]bool = .{ false, false };
            for (0..3) |_| {
                for (0..2) |s| {
                    const start = s == 1;
                    var any = false;
                    for (outcomes(p, k, start)) |landing| {
                        const at: usize = @intFromBool(landing.start);
                        if (!landing.possible) continue;
                        if (bitOf(entered[exit], exit_context, landing.start) or live[at]) any = true;
                    }
                    live[s] = any;
                }
            }
            out = @as(u2, @intFromBool(live[0])) | @as(u2, @intFromBool(live[1])) << 1;
        },
        .lit, .dot, .dot_plain, .any, .class, .sep => {
            const next: usize = if (node.op == .dot) k + 2 else k + 1;
            const context: program_mod.Context = if (node.op == .sep) .sep else .other;
            for (0..2) |s| {
                const start = s == 1;
                for (outcomes(p, k, start)) |landing| {
                    if (landing.possible and bitOf(entered[next], context, landing.start)) out |= @as(u2, 1) << @intCast(s);
                }
            }
        },
        .accept => out = 3,
        .split, .jump => {},
    }
    return out;
}

const Landing = struct { possible: bool, start: bool };

/// Whether node `k`, consuming at a position with `start`, can land on a
/// separator (index 1) and on anything else (index 0).
fn outcomes(p: Program, k: usize, start: bool) [2]Landing {
    const node = p.nodes[k];
    const r = p.reading;
    const hidden_dot = r.leading_dot and start;
    var on_other = false;
    var on_sep = false;
    switch (node.op) {
        .lit => {
            for (preimage(r, @intCast(node.arg))) |code| {
                const c = code orelse continue;
                if (r.isSeparator(c)) on_sep = true else on_other = true;
            }
        },
        .dot, .dot_plain => {
            if (node.op == .dot_plain and hidden_dot) {} else if (r.isSeparator('.')) on_sep = true else on_other = true;
        },
        .sep => on_sep = r.separator != null,
        // Some unit that is neither the separator nor a dot always exists.
        .any, .gstar, .star => {
            on_other = true;
            if (r.separator != null and (node.op == .gstar or (node.op == .star and node.arg == 1))) on_sep = true;
        },
        .class => {
            const reach = classReach(p.classes[node.arg], r);
            on_other = reach.other or (reach.dot and !hidden_dot);
        },
        .split, .jump, .accept => {},
    }
    return .{ .{ .possible = on_other, .start = false }, .{ .possible = on_sep, .start = true } };
}

/// Whether a class holds, among the codes a folded or unfolded subject can
/// show it, a dot and something other than a dot.
fn classReach(class: program_mod.Class, r: program_mod.Reading) struct { other: bool, dot: bool } {
    var other = class.count != 0;
    var dot = false;
    for (0..256) |c| {
        const byte: u8 = @intCast(c);
        if (!class.hasLow(byte)) continue;
        if (r.fold and std.ascii.isUpper(byte)) continue;
        if (byte == '.') dot = true else other = true;
    }
    return .{ .other = other, .dot = dot };
}

/// The raw codes whose canonical form is `canon`.
fn preimage(r: program_mod.Reading, canon: Code) [2]?Code {
    if (!r.fold) return .{ canon, null };
    if (unit.isUpper(canon)) return .{ null, null };
    if (unit.isLower(canon)) return .{ canon, canon - ('a' - 'A') };
    return .{ canon, null };
}

/// Steps closed kernels: the NFA's own step, fed from and read back into
/// sorted lists, with dead threads dropped.
pub const Stepper = struct {
    program: Program,
    live: []const u2,
    sim: nfa.Sim,

    pub fn init(program: Program, live: []const u2, scratch: nfa.Scratch) Stepper {
        return .{ .program = program, .live = live, .sim = .init(program, scratch) };
    }

    /// The start state's kernel into `out`; returns its length.
    pub fn start(s: *Stepper, out: []u32) usize {
        s.sim.reset();
        return s.collect(out);
    }

    /// The kernel after `kernel` (closed at a position with `at_start`)
    /// consumes `code`, into `out`; returns its length.
    pub fn next(s: *Stepper, kernel: []const u32, at_start: bool, code: Code, out: []u32) usize {
        for (s.sim.kernel) |*w| w.* = 0;
        for (kernel) |k| s.sim.kernel[k / 64] |= @as(u64, 1) << @intCast(k % 64);
        s.sim.start = at_start;
        s.sim.units = 0;
        s.sim.steps = 0;
        if (!s.sim.step(code)) return 0;
        return s.collect(out);
    }

    fn collect(s: *Stepper, out: []u32) usize {
        var it = s.sim.threads();
        var n: usize = 0;
        const at_start = s.sim.start;
        while (it.next()) |k| {
            if (!kernelBit(s.live, k, at_start)) continue;
            out[n] = @intCast(k);
            n += 1;
        }
        return n;
    }
};

/// Whether kernel thread `k` at a position with `start` can still match.
pub fn alive(live: []const u2, k: usize, start: bool) bool {
    return kernelBit(live, k, start);
}
