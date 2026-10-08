//! A set's automaton for one reading, and the lazy DFA that runs it: states
//! built on first use into a fixed per-thread cache, cleared when full,
//! and the NFA taking over a query that keeps clearing.
const std = @import("std");
const unit = @import("unit.zig");
const program_mod = @import("program.zig");
const parse = @import("parse.zig");
const nfa = @import("nfa.zig");
const dfa = @import("dfa.zig");

const Allocator = std.mem.Allocator;
const Program = program_mod.Program;

/// The entries of one reading that no strategy decides, as one program
/// whose root forks into each entry.
pub const Automaton = struct {
    nodes: []program_mod.Node = &.{},
    classes: []program_mod.Class = &.{},
    ranges: []program_mod.Range = &.{},
    reading: program_mod.Reading,
    uses_start: bool = false,
    live: []u2 = &.{},
    units: ?dfa.Classes = null,

    pub fn build(gpa: Allocator, entries: anytype, reading: program_mod.Reading) Allocator.Error!Automaton {
        var a: Automaton = .{ .reading = reading };
        errdefer a.deinit(gpa);
        var total: program_mod.Bounds = .{ .nodes = 0, .classes = 0, .ranges = 0, .frames = 0 };
        var count: usize = 0;
        for (entries) |e| {
            if (!e.reading.eql(reading) or e.strategy != null) continue;
            const bounds: program_mod.Bounds = .of(e.pattern, e.entry.options);
            total.nodes += bounds.nodes + 1;
            total.classes += bounds.classes;
            total.ranges += bounds.ranges;
            total.frames = @max(total.frames, bounds.frames);
            count += 1;
        }
        if (count == 0) return a;
        var b: program_mod.Builder = .{
            .nodes = try gpa.alloc(program_mod.Node, total.nodes),
            .classes = &.{},
            .ranges = &.{},
            .frames = &.{},
        };
        defer gpa.free(b.nodes);
        b.classes = try gpa.alloc(program_mod.Class, total.classes);
        defer gpa.free(b.classes);
        b.ranges = try gpa.alloc(program_mod.Range, total.ranges);
        defer gpa.free(b.ranges);
        b.frames = try gpa.alloc(program_mod.Frame, total.frames);
        defer gpa.free(b.frames);
        var seen: usize = 0;
        for (entries, 0..) |e, index| {
            if (!e.reading.eql(reading) or e.strategy != null) continue;
            seen += 1;
            // A fork to this entry and to the next one.
            const fork = if (seen < count) b.emit(.split, 0) catch unreachable else null; // unreachable: sized above
            parse.parse(&b, e.pattern, e.entry.options, .{ .index = @intCast(index), .dir_only = e.entry.dir_only }) catch unreachable; // unreachable: the pattern parsed when it was added
            if (fork) |f| b.nodes[f].arg = @intCast(b.node_len);
        }
        a.nodes = try gpa.dupe(program_mod.Node, b.nodes[0..b.node_len]);
        a.classes = try gpa.dupe(program_mod.Class, b.classes[0..b.class_len]);
        a.ranges = try gpa.dupe(program_mod.Range, b.ranges[0..b.range_len]);
        a.uses_start = b.uses_start;
        a.live = try dfa.liveness(gpa, a.program());
        a.units = try .init(gpa, a.program());
        return a;
    }

    pub fn deinit(a: *Automaton, gpa: Allocator) void {
        gpa.free(a.nodes);
        gpa.free(a.classes);
        gpa.free(a.ranges);
        gpa.free(a.live);
        if (a.units) |*u| u.deinit(gpa);
        a.* = undefined;
    }

    pub fn program(a: *const Automaton) Program {
        return .{ .nodes = a.nodes, .classes = a.classes, .ranges = a.ranges, .reading = a.reading, .uses_start = a.uses_start };
    }

    pub fn isEmpty(a: *const Automaton) bool {
        return a.nodes.len == 0;
    }

    /// Offers every entry matching all of `subject`.
    pub fn visit(a: *const Automaton, c: *Cache, subject: []const u8, acc: anytype) void {
        if (a.isEmpty()) return;
        var run: Run = .begin(a, c);
        if (!run.feed(subject, subject.len)) return;
        run.offer(acc);
    }

    /// Whether some `dir`, a separator, then anything could match.
    pub fn leadsTo(a: *const Automaton, c: *Cache, dir: []const u8) bool {
        if (a.isEmpty()) return false;
        var run: Run = .begin(a, c);
        if (!run.feed(dir, dir.len)) return false;
        if (dir.len > 0) if (a.reading.separator) |s| if (!run.consume(s)) return false;
        return run.alive();
    }
};

/// Counts that show how a cache is doing.
pub const Stats = struct {
    /// States built.
    states: u64 = 0,
    /// Times the cache filled and started over.
    clears: u64 = 0,
    /// Queries finished on the NFA after clearing too often.
    fallbacks: u64 = 0,
};

const unknown = std.math.maxInt(u32);
const dead: u32 = 0;

const State = struct {
    /// Where its kernel and its row are in the arena.
    kernel: u32,
    kernel_len: u32,
    row: u32,
    /// Where its accepted entries are in the arena, ascending.
    accepts: u32,
    accepts_len: u32,
    start: bool,
    hash: u64,
};

/// One thread's states for one automaton, in a fixed allocation.
pub const Cache = struct {
    automaton: *const Automaton,
    /// Kernels, transition rows and accept lists.
    arena: []u32,
    used: usize = 0,
    states: []State,
    state_len: u32 = 0,
    /// State ids by hash, open addressing; `unknown` is empty.
    slots: []u32,
    /// The NFA's scratch, for building states and for the fallback.
    scratch: []u64,
    /// Kernels between steps.
    buf: []u32,
    start: ?u32 = null,
    /// Bumped on every clear: ids from before are stale.
    generation: u32 = 0,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, a: *const Automaton, capacity: usize) Allocator.Error!Cache {
        const nodes = a.nodes.len;
        const class_count = if (a.units) |u| u.count() else 0;
        const max_states = @max(16, capacity / 256);
        const slot_count = std.math.ceilPowerOfTwoAssert(usize, 2 * max_states);
        const fixed = max_states * @sizeOf(State) + slot_count * 4;
        // Room for a few of the largest possible states, whatever the
        // capacity says.
        const arena_words = @max((capacity -| fixed) / 4, 4 * (2 * nodes + class_count) + 64);
        var c: Cache = .{
            .automaton = a,
            .arena = try gpa.alloc(u32, arena_words),
            .states = &.{},
            .slots = &.{},
            .scratch = &.{},
            .buf = &.{},
        };
        errdefer c.deinit(gpa);
        c.states = try gpa.alloc(State, max_states);
        c.slots = try gpa.alloc(u32, slot_count);
        c.scratch = try gpa.alloc(u64, 7 * nfa.words(nodes));
        c.buf = try gpa.alloc(u32, nodes);
        c.clear();
        c.stats.clears = 0;
        return c;
    }

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        gpa.free(c.arena);
        gpa.free(c.states);
        gpa.free(c.slots);
        gpa.free(c.scratch);
        gpa.free(c.buf);
        c.* = undefined;
    }

    fn width(c: *const Cache) usize {
        return if (c.automaton.units) |u| u.count() else 0;
    }

    fn stepper(c: *Cache) dfa.Stepper {
        const n = nfa.words(c.automaton.nodes.len);
        const w = c.scratch;
        return .init(c.automaton.program(), c.automaton.live, .{
            .reach = .{ w[0..n], w[n .. 2 * n], w[2 * n .. 3 * n] },
            .kernel = w[3 * n .. 4 * n],
            .seen = .{ w[4 * n .. 5 * n], w[5 * n .. 6 * n], w[6 * n .. 7 * n] },
        });
    }

    fn clear(c: *Cache) void {
        c.used = 0;
        c.state_len = 0;
        @memset(c.slots, unknown);
        c.generation +%= 1;
        c.stats.clears += 1;
        c.start = null;
        // State 0: dead, every transition back to itself.
        const row = c.alloc(c.width()).?;
        @memset(c.arena[row..][0..c.width()], dead);
        c.states[0] = .{ .kernel = 0, .kernel_len = 0, .row = @intCast(row), .accepts = 0, .accepts_len = 0, .start = false, .hash = 0 };
        c.state_len = 1;
    }

    fn alloc(c: *Cache, words: usize) ?usize {
        if (c.used + words > c.arena.len) return null;
        const at = c.used;
        c.used += words;
        return at;
    }

    fn kernelOf(c: *const Cache, id: u32) []const u32 {
        const s = c.states[id];
        return c.arena[s.kernel..][0..s.kernel_len];
    }

    fn hashOf(kernel: []const u32, start: bool) u64 {
        var h: std.hash.Wyhash = .init(@intFromBool(start));
        h.update(std.mem.sliceAsBytes(kernel));
        return h.final();
    }

    /// The id of the state (`kernel`, `start`), built if new. Clears the
    /// cache first when it is full, which makes every older id stale.
    fn intern(c: *Cache, kernel: []const u32, start: bool) u32 {
        if (kernel.len == 0) return dead;
        const hash = hashOf(kernel, start);
        const mask = c.slots.len - 1;
        var slot: usize = @intCast(hash & mask);
        while (c.slots[slot] != unknown) : (slot = (slot + 1) & mask) {
            const id = c.slots[slot];
            const s = c.states[id];
            if (s.hash == hash and s.start == start and std.mem.eql(u32, c.kernelOf(id), kernel)) return id;
        }
        const nodes = c.automaton.nodes;
        var accepts: usize = 0;
        for (kernel) |k| accepts += @intFromBool(nodes[k].op == .accept);
        const need = kernel.len + c.width() + accepts;
        if (c.state_len >= c.states.len or c.used + need > c.arena.len) {
            // `kernel` lives in `buf`, never in the arena, so it survives,
            // and the empty table has its first slot free. `init` sized the
            // arena for any state beside the dead one.
            c.clear();
            slot = @intCast(hash & mask);
            std.debug.assert(c.state_len < c.states.len);
            std.debug.assert(c.used + need <= c.arena.len);
        }
        const at = c.alloc(need).?;
        @memcpy(c.arena[at..][0..kernel.len], kernel);
        const row = at + kernel.len;
        @memset(c.arena[row..][0..c.width()], unknown);
        const accept_at = row + c.width();
        var n: usize = 0;
        for (kernel) |k| if (nodes[k].op == .accept) {
            c.arena[accept_at + n] = nodes[k].arg >> 1;
            n += 1;
        };
        const id = c.state_len;
        c.states[id] = .{
            .kernel = @intCast(at),
            .kernel_len = @intCast(kernel.len),
            .row = @intCast(row),
            .accepts = @intCast(accept_at),
            .accepts_len = @intCast(n),
            .start = start,
            .hash = hash,
        };
        c.state_len += 1;
        c.slots[slot] = id;
        c.stats.states += 1;
        return id;
    }

    /// The start state; adds to `steps` the states closed to build it.
    fn startState(c: *Cache, steps: *u64) u32 {
        if (c.start) |s| return s;
        var st = c.stepper();
        const n = st.start(c.buf);
        if (std.debug.runtime_safety) steps.* += st.sim.steps;
        const id = c.intern(c.buf[0..n], c.automaton.uses_start);
        c.start = id;
        return id;
    }

    /// The state after `id` consumes `code`. Adds to `steps` one for a
    /// known transition, or the states closed to build a new one.
    fn next(c: *Cache, id: u32, class: u16, code: unit.Code, steps: *u64) u32 {
        const row = c.states[id].row + class;
        const known = c.arena[row];
        if (known != unknown) {
            if (std.debug.runtime_safety) steps.* += 1;
            return known;
        }
        const s = c.states[id];
        var st = c.stepper();
        const n = st.next(c.kernelOf(id), s.start, code, c.buf);
        if (std.debug.runtime_safety) steps.* += @max(1, st.sim.steps);
        const a = c.automaton;
        const generation = c.generation;
        const target = c.intern(c.buf[0..n], a.uses_start and a.reading.isSeparator(code));
        if (c.generation == generation) c.arena[row] = target;
        return target;
    }
};

/// One query through the lazy DFA, finishing on the NFA if the cache
/// thrashes.
const Run = struct {
    automaton: *const Automaton,
    cache: *Cache,
    state: u32,
    /// The query's NFA once it has given up on the cache.
    sim: ?nfa.Sim = null,
    clears: u64,
    built: u64,
    units: u64 = 0,
    /// Work on the cache, counted in safe builds: a known transition is one
    /// step, a new state the (node, context) states closed to build it. The
    /// NFA counts its own after a fallback.
    steps: u64 = 0,

    fn begin(a: *const Automaton, c: *Cache) Run {
        var r: Run = .{ .automaton = a, .cache = c, .state = undefined, .clears = c.stats.clears, .built = c.stats.states };
        r.state = c.startState(&r.steps);
        return r;
    }

    /// Consumes `bytes[0..to]`; false once nothing can match.
    fn feed(r: *Run, bytes: []const u8, to: usize) bool {
        const utf8 = r.automaton.reading.utf8;
        var at: usize = 0;
        while (at < to) {
            const u = unit.decode(utf8, bytes, at);
            if (!r.consume(u.code)) return false;
            at += u.len;
        }
        return true;
    }

    fn consume(r: *Run, code: unit.Code) bool {
        defer if (std.debug.runtime_safety) r.checkBound();
        r.units += 1;
        if (r.sim) |*sim| return sim.step(code);
        const c = r.cache;
        const class = r.automaton.units.?.of(code);
        const before = c.stats.clears;
        r.state = c.next(r.state, class, code, &r.steps);
        if (c.stats.clears != before) {
            // The thrash rule: more than three clears in this query, and
            // more than one new state per ten units since the first.
            const clears = c.stats.clears - r.clears;
            const built = c.stats.states - r.built;
            if (clears > 3 and built * 10 > r.units) r.fallBack();
        }
        if (r.sim) |*sim| {
            var it = sim.threads();
            return it.next() != null;
        }
        return r.state != dead;
    }

    /// The bound the design promises, on the cache and the NFA together:
    /// at most (units + 1) × states steps.
    fn checkBound(r: *const Run) void {
        const after = if (r.sim) |sim| sim.steps else 0;
        std.debug.assert(r.steps + after <= (r.units + 1) * r.automaton.program().states());
    }

    fn fallBack(r: *Run) void {
        const c = r.cache;
        c.stats.fallbacks += 1;
        const n = nfa.words(r.automaton.nodes.len);
        const w = c.scratch;
        var sim: nfa.Sim = .init(r.automaton.program(), .{
            .reach = .{ w[0..n], w[n .. 2 * n], w[2 * n .. 3 * n] },
            .kernel = w[3 * n .. 4 * n],
            .seen = .{ w[4 * n .. 5 * n], w[5 * n .. 6 * n], w[6 * n .. 7 * n] },
        });
        for (sim.reach) |reach| @memset(reach, 0);
        @memset(sim.kernel, 0);
        sim.low = n;
        for (c.kernelOf(r.state)) |k| sim.kernel[k / 64] |= @as(u64, 1) << @intCast(k % 64);
        sim.start = c.states[r.state].start;
        r.sim = sim;
    }

    /// Whether some thread can still match.
    fn alive(r: *Run) bool {
        if (r.sim) |*sim| {
            var it = sim.threads();
            while (it.next()) |k| if (dfa.alive(r.automaton.live, k, sim.start)) return true;
            return false;
        }
        return r.state != dead;
    }

    /// Offers the entries accepted where the run stands.
    fn offer(r: *Run, acc: anytype) void {
        if (r.sim) |*sim| {
            var it = sim.threads();
            var buf: [64]u32 = undefined;
            var n: usize = 0;
            while (it.next()) |k| {
                const node = r.automaton.nodes[k];
                if (node.op != .accept) continue;
                buf[n] = node.arg >> 1;
                n += 1;
                if (n == buf.len) {
                    acc.offerRun(buf[0..n]);
                    n = 0;
                }
            }
            acc.offerRun(buf[0..n]);
            return;
        }
        const s = r.cache.states[r.state];
        acc.offerRun(r.cache.arena[s.accepts..][0..s.accepts_len]);
    }
};

/// A cursor for `Set.ancestors`: a run kept between prefixes.
pub const Cursor = struct {
    run: Run,
    generation: u32,
    /// Bytes of the subject consumed.
    at: usize = 0,
    done: bool = false,

    pub fn begin(a: *const Automaton, c: *Cache) Cursor {
        if (a.isEmpty()) return .{ .run = undefined, .generation = 0, .done = true };
        return .{ .run = .begin(a, c), .generation = c.generation };
    }

    /// Consumes `subject[at..to]`.
    pub fn advance(cur: *Cursor, subject: []const u8, to: usize) void {
        if (cur.done) return;
        const c = cur.run.cache;
        if (cur.run.sim == null and c.generation != cur.generation) {
            // Something else cleared the cache: start over to here.
            const at = cur.at;
            cur.run = .begin(cur.run.automaton, c);
            if (!cur.run.feed(subject, at)) {
                cur.done = true;
                return;
            }
        }
        if (!cur.run.feed(subject[cur.at..], to - cur.at)) cur.done = true;
        cur.at = to;
        cur.generation = c.generation;
    }

    /// Offers the entries accepting the prefix consumed so far.
    pub fn offer(cur: *Cursor, acc: anytype) void {
        if (!cur.done) cur.run.offer(acc);
    }

    /// Whether something could still match after what was consumed.
    pub fn alive(cur: *Cursor) bool {
        return !cur.done and cur.run.alive();
    }

    /// Consumes the separator; false once nothing can match.
    pub fn separator(cur: *Cursor, sep: unit.Code) bool {
        if (cur.done) return false;
        if (!cur.run.consume(sep)) cur.done = true;
        cur.at += 1;
        cur.generation = cur.run.cache.generation;
        return !cur.done and cur.run.alive();
    }
};
