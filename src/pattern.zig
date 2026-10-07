//! A compiled pattern: a literal strategy when one decides it, otherwise a
//! required prefix and suffix checked first, then a small eager DFA, with
//! the NFA as the fallback that keeps the bound.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");
const program_mod = @import("program.zig");
const parse = @import("parse.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");
const strategy_mod = @import("strategy.zig");
const helpers = @import("helpers.zig");

const Allocator = std.mem.Allocator;
const Program = program_mod.Program;

/// Most states the eager DFA builds before the pattern keeps its NFA.
pub const max_dfa_states = 64;
/// Most transitions (states × unit classes) the eager DFA holds.
pub const max_dfa_cells = 4096;
/// Most nodes a pattern's automaton has: two a unit at most, the
/// `anywhere` prefix and the accept. Its NFA runs on stack scratch sized
/// for them, so queries share nothing and allocate nothing.
const max_nodes = 2 * Pattern.max_units + 4;

/// Why a pattern cannot be compiled.
pub const CompileError = errors: {
    // A block, so a linter reading the declaration sees a type.
    break :errors Allocator.Error || syntax.PatternError;
};

/// A pattern compiled once and matched many times. Immutable after
/// `compile`; any number of threads may query it at once.
pub const Pattern = struct {
    /// The longest pattern, in units, `compile` takes. A query that runs
    /// the NFA keeps it on the stack, in about 8 KiB at this length; a
    /// `Set` of one entry takes a longer pattern.
    pub const max_units = 8192;

    /// Private: the allocator everything below came from.
    gpa: Allocator,
    /// Private: the automaton.
    nodes: []program_mod.Node,
    /// Private: the automaton's bracket classes.
    classes: []program_mod.Class,
    /// Private: their ranges.
    ranges: []program_mod.Range,
    /// Private: how the subject is read.
    reading: program_mod.Reading,
    /// Private: whether the automaton reads the component-start bit.
    uses_start: bool,
    /// Private: which kernel threads can still match.
    live: []u2,
    /// Private: a literal strategy that decides the pattern.
    strategy: ?strategy_mod.Strategy,
    /// Private: canonical bytes every match starts with.
    head: []const u8,
    /// Private: canonical bytes every match ends with.
    tail: []const u8,
    /// Private: every literal the pattern keeps, in one allocation.
    literals: []u8,
    /// Private: the eager DFA, when it fit.
    eager: ?Eager,
    /// Private: the walk base, unescaped.
    base_text: []u8,

    /// Compiles `pattern`, which is copied: nothing stays borrowed. Longer
    /// than `max_units` units is `error.PatternTooLong`.
    pub fn compile(gpa: Allocator, pattern: []const u8, options: syntax.Options) CompileError!Pattern {
        if (pattern.len > max_units and unit.count(options.syntax.unit == .utf8, pattern) > max_units) {
            if (options.diagnostics) |d| d.* = .{ .offset = 0, .reason = .too_long };
            return error.PatternTooLong;
        }
        const bounds: program_mod.Bounds = .of(pattern);
        var b: program_mod.Builder = .{
            .nodes = try gpa.alloc(program_mod.Node, bounds.nodes),
            .classes = &.{},
            .ranges = &.{},
            .frames = &.{},
        };
        defer gpa.free(b.nodes);
        b.classes = try gpa.alloc(program_mod.Class, bounds.classes);
        defer gpa.free(b.classes);
        b.ranges = try gpa.alloc(program_mod.Range, bounds.ranges);
        defer gpa.free(b.ranges);
        b.frames = try gpa.alloc(program_mod.Frame, bounds.frames);
        defer gpa.free(b.frames);
        try parse.parse(&b, pattern, options, .{});

        var p: Pattern = .{
            .gpa = gpa,
            .nodes = try gpa.dupe(program_mod.Node, b.nodes[0..b.node_len]),
            .classes = &.{},
            .ranges = &.{},
            .reading = .of(options),
            .uses_start = b.uses_start,
            .live = &.{},
            .strategy = null,
            .head = &.{},
            .tail = &.{},
            .literals = &.{},
            .eager = null,
            .base_text = &.{},
        };
        errdefer p.deinit();
        p.classes = try gpa.dupe(program_mod.Class, b.classes[0..b.class_len]);
        p.ranges = try gpa.dupe(program_mod.Range, b.ranges[0..b.range_len]);
        const prog = p.program();
        p.live = try dfa.liveness(gpa, prog);
        try p.literal(prog);
        p.base_text = try baseOf(gpa, pattern, options);
        if (p.strategy == null) p.eager = try Eager.build(gpa, prog, p.live);
        std.debug.assert(p.nodes.len <= max_nodes);
        return p;
    }

    /// Frees everything `compile` allocated.
    pub fn deinit(p: *Pattern) void {
        const gpa = p.gpa;
        gpa.free(p.nodes);
        gpa.free(p.classes);
        gpa.free(p.ranges);
        gpa.free(p.live);
        gpa.free(p.literals);
        gpa.free(p.base_text);
        if (p.eager) |*e| e.deinit(gpa);
        p.* = undefined;
    }

    /// Whether `subject` matches. Allocates nothing.
    pub fn matches(p: *const Pattern, subject: []const u8) bool {
        return matchesBy(p, subject, .fastest);
    }

    /// The end of the shortest prefix of `subject` that ends at a
    /// separator (exclusive) or at the end and that matches; null if none
    /// does. One pass. In text mode only the whole subject counts.
    pub fn ancestor(p: *const Pattern, subject: []const u8) ?usize {
        const utf8 = p.reading.utf8;
        if (p.eager) |*e| {
            var state = e.start;
            var at: usize = 0;
            while (at < subject.len) {
                const u = unit.decode(utf8, subject, at);
                if (p.reading.isSeparator(u.code) and e.accepts(state)) return at;
                state = e.next(state, u.code);
                if (state == Eager.dead) return null;
                at += u.len;
            }
            return if (e.accepts(state)) subject.len else null;
        }
        return ancestorNfa(p, subject);
    }

    /// Whether some subject `dir`, a separator, then anything (possibly
    /// nothing) could match: a walk must enter `dir`. `""` is the root,
    /// below which the subject is the rest alone. Exact for the pattern's
    /// language. In text mode the subject is `dir` then anything.
    pub fn leadsTo(p: *const Pattern, dir: []const u8) bool {
        const utf8 = p.reading.utf8;
        const sep = p.reading.separator;
        if (p.eager) |*e| {
            var state = e.start;
            var at: usize = 0;
            while (at < dir.len and state != Eager.dead) {
                const u = unit.decode(utf8, dir, at);
                state = e.next(state, u.code);
                at += u.len;
            }
            if (dir.len > 0) if (sep) |s| if (state != Eager.dead) {
                state = e.next(state, s);
            };
            return state != Eager.dead;
        }
        return leadsToNfa(p, dir);
    }

    /// The leading whole components with no special unit, unescaped: where
    /// a walk of this pattern starts (`src/lib` for `src/lib/**/*.zig`).
    /// Empty when the first component is special or `anywhere` applied.
    pub fn base(p: *const Pattern) []const u8 {
        return p.base_text;
    }

    fn program(p: *const Pattern) Program {
        return .{ .nodes = p.nodes, .classes = p.classes, .ranges = p.ranges, .reading = p.reading, .uses_start = p.uses_start };
    }

    fn prefilter(p: *const Pattern, subject: []const u8) bool {
        if (subject.len < p.head.len + p.tail.len) return false;
        return strategy_mod.eql(p.reading, subject[0..p.head.len], p.head) and
            strategy_mod.eql(p.reading, subject[subject.len - p.tail.len ..], p.tail);
    }

    fn literal(p: *Pattern, prog: Program) Allocator.Error!void {
        const shape = strategy_mod.recognise(prog);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(p.gpa);
        if (shape.strategy) |kind| {
            try strategy_mod.bytes(p.gpa, prog, shape.first, shape.end, &out);
            p.literals = try out.toOwnedSlice(p.gpa);
            p.strategy = .{ .kind = kind, .literal = p.literals };
            return;
        }
        try strategy_mod.bytes(p.gpa, prog, 0, shape.head, &out);
        const head_len = out.items.len;
        try strategy_mod.bytes(p.gpa, prog, shape.tail_start, prog.nodes.len - 1, &out);
        p.literals = try out.toOwnedSlice(p.gpa);
        p.head = p.literals[0..head_len];
        p.tail = p.literals[head_len..];
    }
};

/// The eager DFA: at most `max_dfa_states` states over the unit classes,
/// one byte per transition. State 0 is dead.
pub const Eager = struct {
    classes: dfa.Classes,
    /// `table[state * classes + class]`.
    table: []u8,
    /// One bit per accepting state.
    accepting: u64,
    start: u8,

    pub const dead: u8 = 0;

    pub fn deinit(e: *Eager, gpa: Allocator) void {
        e.classes.deinit(gpa);
        gpa.free(e.table);
        e.* = undefined;
    }

    pub fn next(e: *const Eager, state: u8, code: unit.Code) u8 {
        return e.table[@as(usize, state) * e.classes.count() + e.classes.of(code)];
    }

    pub fn accepts(e: *const Eager, state: u8) bool {
        return e.accepting >> @intCast(state) & 1 != 0;
    }

    pub fn matches(e: *const Eager, subject: []const u8, reading: program_mod.Reading) bool {
        var state = e.start;
        const width = e.classes.count();
        if (!reading.utf8) {
            for (subject) |byte| {
                state = e.table[@as(usize, state) * width + e.classes.low[byte]];
                if (state == dead) return false;
            }
        } else {
            var at: usize = 0;
            while (at < subject.len) {
                const u = unit.decode(true, subject, at);
                state = e.next(state, u.code);
                if (state == dead) return false;
                at += u.len;
            }
        }
        return e.accepts(state);
    }

    const Key = struct { start: bool, kernel: []const u32 };

    /// Subset construction over the live kernels; null when it outgrows
    /// the caps.
    pub fn build(gpa: Allocator, p: Program, live: []const u2) Allocator.Error!?Eager {
        var classes: dfa.Classes = try .init(gpa, p);
        errdefer classes.deinit(gpa);
        const width = classes.count();
        if (width * 2 > max_dfa_cells) {
            classes.deinit(gpa);
            return null;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const words = nfa.words(p.nodes.len);
        const scratch: nfa.Scratch = .{
            .reach = .{ try a.alloc(u64, words), try a.alloc(u64, words), try a.alloc(u64, words) },
            .kernel = try a.alloc(u64, words),
        };
        var stepper: dfa.Stepper = .init(p, live, scratch);
        const buf = try a.alloc(u32, p.nodes.len);
        var keys: std.ArrayList(Key) = .empty;
        try keys.append(a, .{ .start = false, .kernel = &.{} });
        var table: std.ArrayList(u8) = .empty;
        defer table.deinit(gpa);
        const first = stepper.start(buf);
        const start = try intern(a, &keys, .{ .start = p.uses_start, .kernel = buf[0..first] }) orelse return giveUp(gpa, &classes);
        var state: usize = 0;
        while (state < keys.items.len) : (state += 1) {
            const key = keys.items[state];
            for (0..width) |c| {
                if (state == dead) {
                    try table.append(gpa, dead);
                    continue;
                }
                const code = classes.reps[c];
                const n = stepper.next(key.kernel, key.start, code, buf);
                const after_start = p.uses_start and p.reading.isSeparator(code);
                const target = try intern(a, &keys, .{ .start = after_start, .kernel = buf[0..n] }) orelse return giveUp(gpa, &classes);
                if (keys.items.len * width > max_dfa_cells) return giveUp(gpa, &classes);
                try table.append(gpa, target);
            }
        }
        var accepting: u64 = 0;
        for (keys.items, 0..) |key, s| {
            for (key.kernel) |k| if (p.nodes[k].op == .accept) {
                accepting |= @as(u64, 1) << @intCast(s);
            };
        }
        return .{ .classes = classes, .table = try table.toOwnedSlice(gpa), .accepting = accepting, .start = start };
    }

    fn giveUp(gpa: Allocator, classes: *dfa.Classes) ?Eager {
        classes.deinit(gpa);
        return null;
    }

    /// The id of `key`, added if new; null past the state cap.
    fn intern(a: Allocator, keys: *std.ArrayList(Key), key: Key) Allocator.Error!?u8 {
        if (key.kernel.len == 0) return dead;
        for (keys.items[1..], 1..) |k, id| {
            if (k.start == key.start and std.mem.eql(u32, k.kernel, key.kernel)) return @intCast(id);
        }
        if (keys.items.len >= max_dfa_states) return null;
        try keys.append(a, .{ .start = key.start, .kernel = try a.dupe(u32, key.kernel) });
        return @intCast(keys.items.len - 1);
    }
};

/// How a query runs, for tests that compare executors: `fastest` is what
/// `Pattern.matches` takes, and `strategy` and `dfa` fall back to the NFA
/// where the pattern has neither. Not exported.
pub const Executor = enum { fastest, strategy, dfa, nfa };

/// Whether `subject` matches `p`, decided by `executor`.
pub fn matchesBy(p: *const Pattern, subject: []const u8, executor: Executor) bool {
    if (executor == .fastest or executor == .strategy) {
        if (p.strategy) |s| return s.matches(p.reading, subject);
    }
    if (executor == .fastest) {
        if (!p.prefilter(subject)) return false;
    }
    if (executor != .nfa) if (p.eager) |*e| return e.matches(subject, p.reading);
    return matchesNfa(p, subject);
}

// The NFA paths keep their scratch in their own frames, so the strategy
// and DFA paths do not carry it.

/// One query's NFA scratch, on the stack: every thread has its own.
const Stack = struct {
    words: [4 * nfa.words(max_nodes)]u64,

    fn sim(s: *Stack, p: *const Pattern) nfa.Sim {
        const n = nfa.words(p.nodes.len);
        const w = &s.words;
        return .init(p.program(), .{
            .reach = .{ w[0..n], w[n .. 2 * n], w[2 * n .. 3 * n] },
            .kernel = w[3 * n .. 4 * n],
        });
    }
};

noinline fn matchesNfa(p: *const Pattern, subject: []const u8) bool {
    var stack: Stack = undefined;
    var sim = stack.sim(p);
    return sim.run(subject);
}

noinline fn ancestorNfa(p: *const Pattern, subject: []const u8) ?usize {
    var stack: Stack = undefined;
    var sim = stack.sim(p);
    sim.reset();
    var at: usize = 0;
    while (at < subject.len) {
        const u = unit.decode(p.reading.utf8, subject, at);
        if (p.reading.isSeparator(u.code) and sim.accepting()) return at;
        if (!sim.step(u.code)) return null;
        at += u.len;
    }
    return if (sim.accepting()) subject.len else null;
}

noinline fn leadsToNfa(p: *const Pattern, dir: []const u8) bool {
    var stack: Stack = undefined;
    var sim = stack.sim(p);
    sim.reset();
    var at: usize = 0;
    while (at < dir.len) {
        const u = unit.decode(p.reading.utf8, dir, at);
        if (!sim.step(u.code)) return false;
        at += u.len;
    }
    if (dir.len > 0) if (p.reading.separator) |s| if (!sim.step(s)) return false;
    var it = sim.threads();
    while (it.next()) |k| if (dfa.alive(p.live, k, sim.start)) return true;
    return false;
}

/// The walk base of `pattern`: its leading whole components with no
/// special unit, escapes removed.
fn baseOf(gpa: Allocator, pattern: []const u8, options: syntax.Options) Allocator.Error![]u8 {
    const sx = options.syntax;
    const sep = sx.separator orelse return gpa.alloc(u8, 0);
    if (options.anywhere and !parse.hasSeparator(pattern, sx)) return gpa.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var kept: usize = 0;
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (sx.escape and c == '\\') {
            if (i + 1 >= pattern.len) break;
            if (pattern[i + 1] == sep) break;
            try out.append(gpa, pattern[i + 1]);
            i += 2;
        } else if (c == sep) {
            kept = out.items.len;
            try out.append(gpa, sep);
            i += 1;
        } else if (helpers.isSpecial(c, sx)) {
            break;
        } else {
            try out.append(gpa, c);
            i += 1;
        }
    }
    out.items.len = kept;
    return out.toOwnedSlice(gpa);
}
