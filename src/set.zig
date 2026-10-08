//! Many patterns matched in one pass: hashed literal strategies for the
//! patterns they decide, and one automaton per reading for the rest, run
//! as a lazy DFA whose states a per-thread cache keeps.
const std = @import("std");
const syntax = @import("syntax.zig");
const program_mod = @import("program.zig");
const parse = @import("parse.zig");
const strategy_mod = @import("strategy.zig");
const tables = @import("tables.zig");
const lazy = @import("lazy.zig");
const direct = @import("direct.zig");

const Allocator = std.mem.Allocator;
const file = @This();

/// What a subject is: a file, or a directory that `dir_only` entries match.
pub const Kind = enum { file, dir };

/// How one entry is matched.
pub const Entry = struct {
    options: syntax.Options = .{},
    /// gitignore's trailing slash: match only when the subject is a directory.
    dir_only: bool = false,
};

/// Why an entry cannot join a set.
pub const AddError = errors: {
    // A block, so a linter reading the declaration sees a type.
    break :errors Allocator.Error || syntax.PatternError || error{
        /// The entry's primary or alternate separator differs from the
        /// first entry's component-boundary grammar.
        SeparatorMismatch,
    };
};

/// Builds a `Set`, one entry at a time.
pub const Builder = struct {
    /// Private: the allocator entries and the set come from.
    gpa: Allocator,
    /// Private: the entries so far.
    entries: std.ArrayList(Stored),

    const Stored = struct {
        pattern: []u8,
        entry: Entry,
        reading: program_mod.Reading,
        /// The literal strategy that decides it, or null for the automaton.
        strategy: ?strategy_mod.Strategy,
    };

    /// An empty builder whose entries and set come from `gpa`.
    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa, .entries = .empty };
    }

    /// Frees the entries not yet built.
    pub fn deinit(b: *Builder) void {
        for (b.entries.items) |e| {
            b.gpa.free(e.pattern);
            if (e.strategy) |s| b.gpa.free(s.literal);
        }
        b.entries.deinit(b.gpa);
        b.* = undefined;
    }

    /// Adds `pattern` and returns its index, in insertion order. On error
    /// nothing is added, so indices stay dense.
    pub fn add(b: *Builder, pattern: []const u8, entry: Entry) AddError!u32 {
        if (b.entries.items.len > 0) {
            const entry_syntax = b.entries.items[0].entry.options.syntax;
            if (entry_syntax.separator != entry.options.syntax.separator or entry_syntax.alternate_separator != entry.options.syntax.alternate_separator)
                return error.SeparatorMismatch;
        }
        if (b.entries.items.len >= max_entries) return error.PatternTooLong;
        const gpa = b.gpa;
        const bounds: program_mod.Bounds = .of(pattern, entry.options);
        var builder: program_mod.Builder = .{
            .nodes = try gpa.alloc(program_mod.Node, bounds.nodes),
            .classes = &.{},
            .ranges = &.{},
            .frames = &.{},
        };
        defer gpa.free(builder.nodes);
        builder.classes = try gpa.alloc(program_mod.Class, bounds.classes);
        defer gpa.free(builder.classes);
        builder.ranges = try gpa.alloc(program_mod.Range, bounds.ranges);
        defer gpa.free(builder.ranges);
        builder.frames = try gpa.alloc(program_mod.Frame, bounds.frames);
        defer gpa.free(builder.frames);
        try parse.parse(&builder, pattern, entry.options, .{});
        const reading: program_mod.Reading = .of(entry.options);
        const program = builder.program(reading);
        var stored: Stored = .{ .pattern = try gpa.dupe(u8, pattern), .entry = entry, .reading = reading, .strategy = null };
        stored.entry.options.diagnostics = null;
        errdefer gpa.free(stored.pattern);
        const shape = strategy_mod.recognise(program);
        if (shape.strategy) |kind| {
            var lit: std.ArrayList(u8) = .empty;
            defer lit.deinit(gpa);
            try strategy_mod.bytes(gpa, program, shape.first, shape.end, &lit);
            const strategy: strategy_mod.Strategy = .{ .kind = kind, .literal = lit.items };
            if (tables.hashable(strategy, reading)) stored.strategy = .{ .kind = kind, .literal = try lit.toOwnedSlice(gpa) };
        }
        errdefer if (stored.strategy) |s| gpa.free(s.literal);
        try b.entries.append(gpa, stored);
        return @intCast(b.entries.items.len - 1);
    }

    /// Builds the set from the entries added, which it takes: the builder
    /// is empty afterwards. The set is immutable and shareable.
    pub fn build(b: *Builder) Allocator.Error!Set {
        const gpa = b.gpa;
        defer {
            for (b.entries.items) |e| {
                gpa.free(e.pattern);
                if (e.strategy) |s| gpa.free(s.literal);
            }
            b.entries.clearRetainingCapacity();
        }
        const entries = b.entries.items;
        var set: Set = .{ .gpa = gpa, .count = @intCast(entries.len), .dir_only = &.{}, .parts = &.{}, .separator = null };
        errdefer set.deinit();
        set.dir_only = try gpa.alloc(bool, entries.len);
        for (entries, set.dir_only) |e, *d| d.* = e.entry.dir_only;
        if (entries.len > 0) {
            set.separator = entries[0].entry.options.syntax.separator;
            set.alternate_separator = entries[0].entry.options.syntax.alternate_separator;
        }
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(gpa);
        errdefer for (parts.items) |*p| p.deinit(gpa);
        for (entries) |e| {
            for (parts.items) |p| {
                if (p.reading.eql(e.reading)) break;
            } else {
                try parts.ensureUnusedCapacity(gpa, 1);
                parts.appendAssumeCapacity(try Part.build(gpa, entries, e.reading));
            }
        }
        set.parts = try parts.toOwnedSlice(gpa);
        return set;
    }
};

/// Entries a set holds at most.
pub const max_entries = 1 << 26;

/// Patterns matched together. Immutable and shareable across threads; each
/// thread queries through a `Cache` of its own.
pub const Set = struct {
    pub const Entry = file.Entry;
    pub const Builder = file.Builder;
    pub const AddError = file.AddError;
    pub const Kind = file.Kind;

    /// Private: the allocator the set came from.
    gpa: Allocator,
    /// Private: how many entries.
    count: u32,
    /// Private: each entry's `dir_only`.
    dir_only: []bool,
    /// Private: one per reading.
    parts: []Part,
    /// Private: where `ancestors` stops.
    separator: ?u8,
    /// Private: another spelling of the same component boundary.
    alternate_separator: ?u8 = null,

    fn separatorAt(s: *const Set, subject: []const u8, at: usize) ?usize {
        const sep = s.separator orelse return null;
        if (s.alternate_separator) |alternate|
            return std.mem.findAnyPos(u8, subject, at, &.{ sep, alternate });
        return std.mem.findScalarPos(u8, subject, at, sep);
    }

    /// Frees the set; caches made for it are no use afterwards.
    pub fn deinit(s: *Set) void {
        for (s.parts) |*p| p.deinit(s.gpa);
        s.gpa.free(s.parts);
        s.gpa.free(s.dir_only);
        s.* = undefined;
    }

    /// How many entries the set holds.
    pub fn len(s: *const Set) u32 {
        return s.count;
    }

    /// Per-thread scratch for the lazy DFAs. Allocates once at `init`;
    /// queries never allocate. When full it is cleared and refilled; a
    /// query that keeps clearing finishes on the NFA, so the O(n·m) bound
    /// holds at any capacity.
    pub const Cache = struct {
        /// Private: the allocator the cache came from.
        gpa: Allocator,
        /// Private: one per part of the set.
        parts: []PartCache,

        pub const Options = struct {
            /// Bytes for each reading's states, at least 64 KiB.
            capacity: usize = 1 << 21,
        };

        /// Counts that show how a cache is doing: states built, clears,
        /// and queries finished on the NFA.
        pub const Stats = lazy.Stats;

        /// A cache for queries on `s` from one thread, allocated once.
        pub fn init(gpa: Allocator, s: *const Set, options: Options) Allocator.Error!Set.Cache {
            const parts = try gpa.alloc(PartCache, s.parts.len);
            var done: usize = 0;
            errdefer {
                for (parts[0..done]) |*p| p.lazy.deinit(gpa);
                gpa.free(parts);
            }
            for (s.parts, parts) |*part, *c| {
                c.* = .{ .lazy = try .init(gpa, &part.automaton, @max(options.capacity, 1 << 16)) };
                done += 1;
            }
            return .{ .gpa = gpa, .parts = parts };
        }

        /// Frees the cache.
        pub fn deinit(c: *Cache) void {
            for (c.parts) |*p| p.lazy.deinit(c.gpa);
            c.gpa.free(c.parts);
            c.* = undefined;
        }

        /// States built, clears and NFA fallbacks so far, over all readings.
        /// Clears mean the capacity is short for the subjects queried.
        pub fn stats(c: *const Cache) Stats {
            var total: Stats = .{};
            for (c.parts) |p| {
                total.states += p.lazy.stats.states;
                total.clears += p.lazy.stats.clears;
                total.fallbacks += p.lazy.stats.fallbacks;
            }
            return total;
        }
    };

    /// One reading's cache, and where an `ancestors` pass stands in it.
    const PartCache = struct {
        lazy: lazy.Cache,
        cursor: lazy.Cursor = undefined,
        probe: tables.Probe = .{},
        /// Prefix entries matched so far in an `ancestors` pass.
        prefixes: Prefixes = .{},
        components: Prefixes = .{},
    };

    /// The best prefix-strategy entries an `ancestors` pass has met.
    const Prefixes = struct {
        set: ?*const Set = null,
        any: ?u32 = null,
        file: ?u32 = null,

        pub fn offerRun(p: *Prefixes, entries: []const u32) void {
            for (entries) |index| {
                p.any = if (p.any) |b| @max(b, index) else index;
                if (!p.set.?.dir_only[index]) p.file = if (p.file) |b| @max(b, index) else index;
            }
        }
    };

    /// Whether any entry matches.
    pub fn any(s: *const Set, c: *Cache, subject: []const u8, kind: file.Kind) bool {
        var acc: Accumulator = .{ .set = s, .kind = kind, .mode = .any };
        s.run(c, subject, &acc);
        return acc.found;
    }

    /// The lowest matching index.
    pub fn first(s: *const Set, c: *Cache, subject: []const u8, kind: file.Kind) ?u32 {
        var acc: Accumulator = .{ .set = s, .kind = kind, .mode = .first };
        s.run(c, subject, &acc);
        return acc.best;
    }

    /// The highest matching index (gitignore's last match).
    pub fn last(s: *const Set, c: *Cache, subject: []const u8, kind: file.Kind) ?u32 {
        var acc: Accumulator = .{ .set = s, .kind = kind, .mode = .last };
        s.run(c, subject, &acc);
        return acc.best;
    }

    /// Appends every matching index, ascending, without duplicates.
    pub fn all(s: *const Set, gpa: Allocator, c: *Cache, subject: []const u8, kind: file.Kind, out: *std.ArrayList(u32)) Allocator.Error!void {
        const from = out.items.len;
        var acc: Accumulator = .{ .set = s, .kind = kind, .mode = .all, .gpa = gpa, .out = out };
        s.run(c, subject, &acc);
        if (acc.failed) return error.OutOfMemory;
        const added = out.items[from..];
        std.mem.sortUnstable(u32, added, {}, std.sort.asc(u32));
        var n: usize = 0;
        for (added) |x| {
            if (n > 0 and added[n - 1] == x) continue;
            added[n] = x;
            n += 1;
        }
        out.items.len = from + n;
    }

    /// Whether some subject `dir`, a separator, then anything could match;
    /// `""` is the root.
    pub fn leadsTo(s: *const Set, c: *Cache, dir: []const u8) bool {
        for (s.parts, c.parts) |*part, *cache| {
            if (part.strategies.leadsTo(dir, part.reading)) return true;
            if (part.automaton.leadsTo(&cache.lazy, dir)) return true;
        }
        return false;
    }

    /// One pass over `subject`, stopping at each separator and at the end.
    /// The pass keeps its place in `c`, so one cache serves one pass at a
    /// time; another query on `c` between steps can make a step re-read
    /// the subject from its start.
    pub fn ancestors(s: *const Set, c: *Cache, subject: []const u8, kind: file.Kind) Ancestors {
        for (s.parts, c.parts) |*part, *pc| {
            pc.cursor = .begin(&part.automaton, &pc.lazy);
            pc.probe = .{};
            pc.prefixes = .{ .set = s };
            pc.components = .{ .set = s };
        }
        return .{ .set = s, .cache = c, .subject = subject, .kind = kind };
    }

    /// The prefixes of a subject, shortest first.
    pub const Ancestors = struct {
        set: *const Set,
        cache: *Cache,
        subject: []const u8,
        kind: file.Kind,
        /// Private: where the next prefix's end is looked for.
        at: usize = 0,
        /// Private: whether the whole subject was given.
        done: bool = false,

        pub const Step = struct {
            /// `subject[0..end]` is this prefix.
            end: usize,
            /// The last entry matching this prefix; a proper prefix counts
            /// as a directory.
            last: ?u32,
            /// Whether something below this prefix could still match.
            leads: bool,
        };

        /// The next prefix, or null after the whole subject.
        pub fn next(a: *Ancestors) ?Step {
            if (a.done) return null;
            const s = a.set;
            const subject = a.subject;
            const end = s.separatorAt(subject, a.at) orelse subject.len;
            const whole = end == subject.len;
            const kind: file.Kind = if (whole) a.kind else .dir;
            var acc: Accumulator = .{ .set = s, .kind = kind, .mode = .last };
            var leads = false;
            for (s.parts, a.cache.parts) |*part, *pc| {
                if (s.separatorAt(subject[pc.probe.at..end], 0) != null) pc.components = .{ .set = s };
                pc.probe.feed(&part.strategies, subject, end, part.reading, &pc.prefixes, &pc.components);
                pc.probe.finish(&part.strategies, subject, end, part.reading, &acc);
                if (if (kind == .dir) pc.prefixes.any else pc.prefixes.file) |index| acc.offer(index);
                if (if (kind == .dir) pc.components.any else pc.components.file) |index| acc.offer(index);
                pc.cursor.advance(subject, end);
                pc.cursor.offer(&acc);
                if (!leads) leads = part.strategies.leadsTo(subject[0..end], part.reading);
                // The empty prefix is the root: nothing to cross into it.
                const sep = part.reading.separator;
                const automaton_leads = if (end == 0 or sep == null) pc.cursor.alive() else pc.cursor.separator(sep.?);
                if (end == 0 and !whole) _ = pc.cursor.separator(sep.?);
                leads = leads or automaton_leads;
            }
            if (whole) a.done = true else a.at = end + 1;
            return .{ .end = end, .last = acc.best, .leads = leads };
        }
    };

    fn run(s: *const Set, c: *Cache, subject: []const u8, acc: *Accumulator) void {
        for (s.parts, c.parts) |*part, *cache| {
            part.strategies.visit(subject, part.reading, acc);
            if (acc.mode == .any and acc.found) return;
            if (part.single) |single| {
                if (single.compiled.matches(single.source, subject)) acc.offer(single.index);
            } else part.automaton.visit(&cache.lazy, subject, acc);
        }
    }
};

/// Collects matching entries for one query.
pub const Accumulator = struct {
    set: *const Set,
    kind: file.Kind,
    mode: enum { any, first, last, all },
    found: bool = false,
    best: ?u32 = null,
    gpa: ?Allocator = null,
    out: ?*std.ArrayList(u32) = null,
    failed: bool = false,

    /// Whether entry `index` counts for this kind of subject.
    pub fn counts(acc: *const Accumulator, index: u32) bool {
        return acc.kind == .dir or !acc.set.dir_only[index];
    }

    /// Offers one matching entry.
    pub fn offer(acc: *Accumulator, index: u32) void {
        if (!acc.counts(index)) return;
        acc.found = true;
        switch (acc.mode) {
            .any => {},
            .first => acc.best = if (acc.best) |b| @min(b, index) else index,
            .last => acc.best = if (acc.best) |b| @max(b, index) else index,
            .all => acc.out.?.append(acc.gpa.?, index) catch {
                acc.failed = true;
            },
        }
    }

    /// Offers entries in ascending order; stops early where it can.
    pub fn offerRun(acc: *Accumulator, run: []const u32) void {
        switch (acc.mode) {
            .last => {
                var i = run.len;
                while (i > 0) {
                    i -= 1;
                    if (acc.counts(run[i])) return acc.offer(run[i]);
                }
            },
            .first, .any => for (run) |index| if (acc.counts(index)) return acc.offer(index),
            .all => for (run) |index| acc.offer(index),
        }
    }
};

/// The entries of one reading.
const Part = struct {
    reading: program_mod.Reading,
    strategies: tables.Strategies,
    automaton: lazy.Automaton,
    single: ?struct { source: []u8, compiled: direct.Compiled, index: u32 } = null,

    fn build(gpa: Allocator, entries: []const Builder.Stored, reading: program_mod.Reading) Allocator.Error!Part {
        var strategies: tables.Strategies = try .build(gpa, entries, reading);
        errdefer strategies.deinit(gpa);
        var automaton: lazy.Automaton = try .build(gpa, entries, reading);
        errdefer automaton.deinit(gpa);
        var part: Part = .{ .reading = reading, .strategies = strategies, .automaton = automaton };
        var only: ?usize = null;
        for (entries, 0..) |entry, index| if (entry.reading.eql(reading) and entry.strategy == null) {
            if (only != null) return part;
            only = index;
        };
        if (only) |index| {
            const entry = entries[index];
            if (direct.Compiled.init(entry.pattern, entry.entry.options, entry.pattern.len, .{ .units = entry.pattern.len, .brackets = entry.pattern.len })) |compiled| part.single = .{
                .source = try gpa.dupe(u8, entry.pattern),
                .compiled = compiled,
                .index = @intCast(index),
            };
        }
        return part;
    }

    fn deinit(p: *Part, gpa: Allocator) void {
        p.strategies.deinit(gpa);
        p.automaton.deinit(gpa);
        if (p.single) |single| gpa.free(single.source);
        p.* = undefined;
    }
};
