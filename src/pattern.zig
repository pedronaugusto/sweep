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
const direct = @import("direct.zig");
const capture = @import("capture.zig");
const match_mod = @import("match.zig");

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
    /// the NFA keeps it on the stack, in about 14 KiB at this length; a
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
    /// Private: whether closure needs visited-context tracking.
    cyclic: bool = false,
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
    /// Private: copied source and its dialect, for direct execution and captures.
    source: []const u8,
    options: syntax.Options,
    direct: ?direct.Compiled,
    /// Private: fixed-width suffix after a star, optionally at any depth.
    terminal: ?struct { first: usize, anywhere: bool } = null,

    /// Compiles `pattern`, which is copied: nothing stays borrowed. Longer
    /// than `max_units` units is `error.PatternTooLong`.
    pub fn compile(gpa: Allocator, pattern: []const u8, options: syntax.Options) CompileError!Pattern {
        if (pattern.len > max_units and unit.count(options.syntax.unit == .utf8 or options.case == .unicode or options.normalization == .nfc, pattern) > max_units) {
            if (options.diagnostics) |d| d.* = .{ .offset = 0, .reason = .too_long };
            return error.PatternTooLong;
        }
        const sx = options.syntax;
        if (sx.alternate_separator == null and options.normalization == .exact and options.case == .sensitive and sx.unit == .byte and sx.leading_dot == .ordinary and !options.anywhere and !sx.basename and !sx.root_slash and helpers.literalPrefix(pattern, sx) == pattern.len)
            return compileLiteral(gpa, pattern, options);
        const bounds: program_mod.Bounds = .of(pattern, options);
        var storage: match_mod.Storage = undefined;
        const small = bounds.nodes <= storage.nodes.len and bounds.classes <= storage.classes.len and bounds.ranges <= storage.ranges.len and bounds.frames <= storage.frames.len;
        var b: program_mod.Builder = .{
            .nodes = if (small) &storage.nodes else try gpa.alloc(program_mod.Node, bounds.nodes),
            .classes = &.{},
            .ranges = &.{},
            .frames = &.{},
        };
        defer if (!small) gpa.free(b.nodes);
        b.classes = if (small) &storage.classes else try gpa.alloc(program_mod.Class, bounds.classes);
        defer if (!small) gpa.free(b.classes);
        b.ranges = if (small) &storage.ranges else try gpa.alloc(program_mod.Range, bounds.ranges);
        defer if (!small) gpa.free(b.ranges);
        b.frames = if (small) &storage.frames else try gpa.alloc(program_mod.Frame, bounds.frames);
        defer if (!small) gpa.free(b.frames);
        try parse.parse(&b, pattern, options, .{});

        var p: Pattern = .{
            .gpa = gpa,
            .nodes = try gpa.dupe(program_mod.Node, b.nodes[0..b.node_len]),
            .classes = &.{},
            .ranges = &.{},
            .reading = .of(options),
            .uses_start = b.uses_start,
            .cyclic = b.cyclic,
            .live = &.{},
            .strategy = null,
            .head = &.{},
            .tail = &.{},
            .literals = &.{},
            .eager = null,
            .base_text = &.{},
            .source = &.{},
            .options = options,
            .direct = null,
        };
        errdefer p.deinit();
        p.classes = try gpa.dupe(program_mod.Class, b.classes[0..b.class_len]);
        p.ranges = try gpa.dupe(program_mod.Range, b.ranges[0..b.range_len]);
        p.options.diagnostics = null;
        const prog = p.program();
        if (!p.reading.utf8 and !p.reading.leading_dot) {
            const at: usize = if (p.nodes.len >= 4 and p.nodes[0].op == .gstar and p.nodes[1].op == .sep and p.nodes[1].arg == 0) 2 else 0;
            if (p.nodes[at].op == .star) {
                var fixed = at + 1;
                while (fixed < p.nodes.len - 1 and (p.nodes[fixed].op == .lit or p.nodes[fixed].op == .any or p.nodes[fixed].op == .class)) : (fixed += 1) {}
                if (fixed == p.nodes.len - 1) p.terminal = .{ .first = at + 1, .anywhere = at == 2 or p.nodes[at].arg == 1 };
            }
        }
        p.live = try dfa.liveness(gpa, prog);
        try p.literal(prog, pattern);
        if (p.strategy == null) p.direct = direct.Compiled.init(pattern, options, b.class_len, .{ .units = max_units, .brackets = bounds.classes });
        p.base_text = try baseOf(gpa, pattern, options);
        if (p.strategy == null and p.direct == null) p.eager = try Eager.build(gpa, prog, p.live);
        if (p.nodes.len > max_nodes) {
            if (options.diagnostics) |d| d.* = .{ .offset = 0, .reason = .too_long };
            return error.PatternTooLong;
        }
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
        if (p.eager) |*e| {
            var state = e.start;
            var reader = p.reading.iterator(subject);
            var at: usize = 0;
            while (reader.next()) |cp| {
                if (p.reading.isSeparator(cp) and e.accepts(state)) return at;
                state = e.next(state, cp);
                if (state == Eager.dead) return null;
                at = reader.at;
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
        const sep = p.reading.separator;
        if (p.eager) |*e| {
            var state = e.start;
            var reader = p.reading.iterator(dir);
            while (reader.next()) |cp| {
                state = e.next(state, cp);
                if (state == Eager.dead) break;
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

    /// A byte range captured by a wildcard or group.
    pub const Capture = capture.Capture;
    /// Per-thread scratch for the optional capture pass.
    pub const CaptureCache = capture.Cache;
    /// The output buffer cannot hold this pattern's captures.
    pub const CaptureError = capture.MatchError;

    /// Builds capture scratch once. This pattern must outlive the cache.
    pub fn captureCache(p: *const Pattern, gpa: Allocator) capture.InitError!CaptureCache {
        return .init(gpa, p.source, p.options);
    }

    /// Captures wildcard and group byte ranges, using a cache made for this
    /// pattern. Output slots follow lexical opening order; unmatched items
    /// are null. Stars are greedy, alternatives prefer the first match.
    /// No allocation occurs after captureCache. Output changes only on a match.
    pub fn captures(p: *const Pattern, cache: *CaptureCache, subject: []const u8, out: []?Capture) CaptureError!bool {
        std.debug.assert(cache.source.ptr == p.source.ptr);
        std.debug.assert(cache.source.len == p.source.len);
        return cache.matches(subject, out);
    }

    fn program(p: *const Pattern) Program {
        return .{ .nodes = p.nodes, .classes = p.classes, .ranges = p.ranges, .reading = p.reading, .uses_start = p.uses_start, .cyclic = p.cyclic };
    }

    fn prefilter(p: *const Pattern, subject: []const u8) bool {
        if (subject.len < p.head.len + p.tail.len) return false;
        return strategy_mod.eql(p.reading, subject[0..p.head.len], p.head) and
            strategy_mod.eql(p.reading, subject[subject.len - p.tail.len ..], p.tail);
    }

    fn literal(p: *Pattern, prog: Program, source: []const u8) Allocator.Error!void {
        const shape = strategy_mod.recognise(prog);
        var out = try std.ArrayList(u8).initCapacity(p.gpa, 2 * source.len);
        defer out.deinit(p.gpa);
        var head_len: usize = 0;
        if (shape.strategy != null) {
            try strategy_mod.bytes(p.gpa, prog, shape.first, shape.end, &out);
        } else {
            try strategy_mod.bytes(p.gpa, prog, 0, shape.head, &out);
            head_len = out.items.len;
            try strategy_mod.bytes(p.gpa, prog, shape.tail_start, prog.nodes.len - 1, &out);
        }
        const literal_len = out.items.len;
        try out.appendSlice(p.gpa, source);
        // Source and canonical literals have one owner. Keeping the allocated
        // capacity avoids a shrink and preserves every borrowed slice.
        p.literals = out.allocatedSlice();
        out = .empty;
        p.source = p.literals[literal_len .. literal_len + source.len];
        if (shape.strategy) |kind| p.strategy = .{ .kind = kind, .literal = p.literals[0..literal_len] } else {
            p.head = p.literals[0..head_len];
            p.tail = p.literals[head_len..literal_len];
        }
    }
};

// A plain exact byte literal needs neither parser scratch nor closure analysis.
fn compileLiteral(gpa: Allocator, text: []const u8, options: syntax.Options) CompileError!Pattern {
    var p: Pattern = .{
        .gpa = gpa,
        .nodes = try gpa.alloc(program_mod.Node, text.len + 1),
        .classes = &.{},
        .ranges = &.{},
        .reading = .of(options),
        .uses_start = false,
        .live = &.{},
        .strategy = null,
        .head = &.{},
        .tail = &.{},
        .literals = &.{},
        .eager = null,
        .base_text = &.{},
        .source = &.{},
        .options = options,
        .direct = null,
    };
    errdefer p.deinit();
    p.options.diagnostics = null;
    for (text, p.nodes[0..text.len]) |byte, *node| node.* = if (p.reading.isSeparator(byte)) .{ .op = .sep, .arg = 0 } else .{ .op = .lit, .arg = byte };
    p.nodes[text.len] = .{ .op = .accept, .arg = 0 };
    p.live = try gpa.alloc(u2, p.nodes.len);
    @memset(p.live, 3);
    p.literals = try gpa.dupe(u8, text);
    p.source = p.literals;
    p.strategy = .{ .kind = .exact, .literal = p.literals };
    const end = if (options.syntax.separator) |sep| std.mem.findScalarLast(u8, text, sep) orelse 0 else 0;
    p.base_text = try gpa.dupe(u8, text[0..end]);
    return p;
}

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
            if (reading.alternate_separator != null or (reading.nfc and !unit.isAscii(subject))) {
                var reader = reading.iterator(subject);
                while (reader.next()) |cp| {
                    state = e.next(state, cp);
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
            .seen = .{ try a.alloc(u64, words), try a.alloc(u64, words), try a.alloc(u64, words) },
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
        if (p.terminal) |tail| {
            const width = p.nodes.len - 1 - tail.first;
            if (subject.len < width) return false;
            const from = subject.len - width;
            if (!tail.anywhere) if (p.reading.separator) |sep| if (std.mem.findScalar(u8, subject[0..from], @intCast(sep)) != null) return false;
            const prog = p.program();
            for (subject[from..], tail.first..) |byte, k| if (!prog.consumes(k, byte, false)) return false;
            return true;
        }
        if (p.direct) |c| return c.matches(p.source, subject);
    }
    if (executor != .nfa) if (p.eager) |*e| return e.matches(subject, p.reading);
    return matchesNfa(p, subject);
}

// The NFA paths keep their scratch in their own frames, so the strategy
// and DFA paths do not carry it.

/// One query's NFA scratch, on the stack: every thread has its own.
const Stack = struct {
    words: [7 * nfa.words(max_nodes)]u64,

    fn sim(s: *Stack, p: *const Pattern) nfa.Sim {
        const n = nfa.words(p.nodes.len);
        const w = &s.words;
        return .init(p.program(), .{
            .reach = .{ w[0..n], w[n .. 2 * n], w[2 * n .. 3 * n] },
            .kernel = w[3 * n .. 4 * n],
            .seen = .{ w[4 * n .. 5 * n], w[5 * n .. 6 * n], w[6 * n .. 7 * n] },
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
    var reader = p.reading.iterator(subject);
    var at: usize = 0;
    while (reader.next()) |cp| {
        if (p.reading.isSeparator(cp) and sim.accepting()) return at;
        if (!sim.step(cp)) return null;
        at = reader.at;
    }
    return if (sim.accepting()) subject.len else null;
}

noinline fn leadsToNfa(p: *const Pattern, dir: []const u8) bool {
    var stack: Stack = undefined;
    var sim = stack.sim(p);
    sim.reset();
    var reader = p.reading.iterator(dir);
    while (reader.next()) |cp| if (!sim.step(cp)) return false;
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
    if ((options.anywhere or sx.basename) and !parse.hasSeparator(pattern, sx)) return gpa.alloc(u8, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var kept: usize = 0;
    var i: usize = if (sx.root_slash and pattern.len > 0 and pattern[0] == sep) 1 else 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (sx.escape and c == '\\') {
            if (i + 1 >= pattern.len) break;
            if (pattern[i + 1] == sep) break;
            try out.append(gpa, pattern[i + 1]);
            i += 2;
        } else if (c == sep or (sx.alternate_separator != null and c == sx.alternate_separator.?)) {
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
