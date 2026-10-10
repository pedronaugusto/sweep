//! A set's hashed strategies: whole paths, base names, extensions,
//! directory prefixes and path suffixes, each looked up by a hash rolled
//! along the subject in one pass.
// aegis: measured-boundary: docs/design.md#safety-boundaries; table construction receives validated insertion-order entries; private query IDs never cross into another domain.
const std = @import("std");
const unit = @import("unit.zig");
const program_mod = @import("program.zig");
const strategy_mod = @import("strategy.zig");

const Allocator = std.mem.Allocator;
const Reading = program_mod.Reading;
const Strategy = strategy_mod.Strategy;

/// Whether a set can hash `s` rather than put it in its automaton.
pub fn hashable(s: Strategy, reading: Reading) bool {
    const sep = reading.separator orelse return s.kind == .exact;
    if (sep >= 0x80) return false;
    const sep_byte: u8 = @intCast(sep);
    const lit = s.literal;
    return switch (s.kind) {
        .exact => true,
        .tail => lit.len > 0 and lit[lit.len - 1] != sep_byte,
        .ends => lit.len > 1 and lit[0] == '.' and std.mem.findAny(u8, lit[1..], &.{ '.', sep_byte }) == null,
        .starts => lit.len > 0 and lit[lit.len - 1] == sep_byte,
        .starts_component => true,
        .basename_starts, .within => false,
    };
}

const multiplier: u64 = 0x100000001b3;

fn canonical(reading: Reading, byte: u8) u8 {
    return if (reading.fold) std.ascii.toLower(byte) else byte;
}

/// The rolling hash of canonical bytes.
fn roll(h: u64, byte: u8) u64 {
    return h *% multiplier +% byte +% 1;
}

fn hashOf(reading: Reading, bytes: []const u8) u64 {
    var h: u64 = 0;
    for (bytes) |b| h = roll(h, canonical(reading, b));
    return h;
}

/// Keys to sorted runs of entry indices, by open addressing.
const Table = struct {
    slots: []Slot = &.{},
    keys: []u8 = &.{},
    runs: []u32 = &.{},

    const Slot = struct {
        hash: u64,
        key: u32,
        key_len: u32,
        run: u32,
        run_len: u32,
    };

    const empty_run = std.math.maxInt(u32);

    const Pair = struct { key: []const u8, index: u32 };

    fn build(gpa: Allocator, reading: Reading, pairs: []Pair) Allocator.Error!Table {
        if (pairs.len == 0) return .{};
        std.mem.sortUnstable(Pair, pairs, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                return switch (std.mem.order(u8, a.key, b.key)) {
                    .lt => true,
                    .gt => false,
                    .eq => a.index < b.index,
                };
            }
        }.less);
        var distinct: usize = 0;
        var key_bytes: usize = 0;
        for (pairs, 0..) |pair, i| if (i == 0 or !std.mem.eql(u8, pairs[i - 1].key, pair.key)) {
            distinct += 1;
            key_bytes += pair.key.len;
        };
        var t: Table = .{};
        errdefer t.deinit(gpa);
        t.slots = try gpa.alloc(Slot, std.math.ceilPowerOfTwoAssert(usize, 2 * distinct));
        for (t.slots) |*s| s.run = empty_run;
        t.keys = try gpa.alloc(u8, key_bytes);
        t.runs = try gpa.alloc(u32, pairs.len);
        var key_at: usize = 0;
        var i: usize = 0;
        while (i < pairs.len) {
            var j = i;
            while (j < pairs.len and std.mem.eql(u8, pairs[j].key, pairs[i].key)) : (j += 1) t.runs[j] = pairs[j].index;
            const key = pairs[i].key;
            @memcpy(t.keys[key_at..][0..key.len], key);
            const hash = hashOf(reading, key);
            var slot = t.home(hash);
            while (t.slots[slot].run != empty_run) slot = (slot + 1) & (t.slots.len - 1);
            t.slots[slot] = .{ .hash = hash, .key = @intCast(key_at), .key_len = @intCast(key.len), .run = @intCast(i), .run_len = @intCast(j - i) };
            key_at += key.len;
            i = j;
        }
        return t;
    }

    fn deinit(t: *Table, gpa: Allocator) void {
        gpa.free(t.slots);
        gpa.free(t.keys);
        gpa.free(t.runs);
        t.* = undefined;
    }

    fn home(t: *const Table, hash: u64) usize {
        const bits: u6 = @intCast(@ctz(t.slots.len));
        if (bits == 0) return 0;
        return @intCast((hash *% 0x9E3779B97F4A7C15) >> @intCast(@as(u7, 64) - bits));
    }

    /// The run of entries whose key is `subject`, given its hash.
    fn find(t: *const Table, reading: Reading, hash: u64, subject: []const u8) ?[]const u32 {
        if (t.slots.len == 0) return null;
        var slot = t.home(hash);
        while (t.slots[slot].run != empty_run) : (slot = (slot + 1) & (t.slots.len - 1)) {
            const s = t.slots[slot];
            if (s.hash != hash or s.key_len != subject.len) continue;
            if (!strategy_mod.eql(reading, subject, t.keys[s.key..][0..s.key_len])) continue;
            return t.runs[s.run..][0..s.run_len];
        }
        return null;
    }

    fn isEmpty(t: *const Table) bool {
        return t.slots.len == 0;
    }
};

/// Path suffixes of one length in components.
const Suffixes = struct {
    components: usize,
    table: Table,
};

/// Every hashed strategy of one reading.
pub const Strategies = struct {
    /// The whole subject.
    exact: Table = .{},
    /// The last component.
    basename: Table = .{},
    /// What follows the last dot of the last component.
    extension: Table = .{},
    /// A prefix ending in a separator.
    prefix: Table = .{},
    /// Prefixes whose remainder cannot contain a separator.
    component_prefix: Table = .{},
    component_sorted: [][]const u8 = &.{},
    /// The last few components.
    suffixes: []Suffixes = &.{},
    /// Exact keys and prefix keys, sorted, for `leadsTo`.
    exact_sorted: [][]const u8 = &.{},
    prefix_sorted: [][]const u8 = &.{},

    pub fn build(gpa: Allocator, entries: anytype, reading: Reading) Allocator.Error!Strategies {
        var s: Strategies = .{};
        errdefer s.deinit(gpa);
        var exact: std.ArrayList(Table.Pair) = .empty;
        defer exact.deinit(gpa);
        var basename: std.ArrayList(Table.Pair) = .empty;
        defer basename.deinit(gpa);
        var extension: std.ArrayList(Table.Pair) = .empty;
        defer extension.deinit(gpa);
        var component: std.ArrayList(Table.Pair) = .empty;
        defer component.deinit(gpa);
        var prefix: std.ArrayList(Table.Pair) = .empty;
        defer prefix.deinit(gpa);
        var suffix: std.ArrayList(struct { components: usize, pair: Table.Pair }) = .empty;
        defer suffix.deinit(gpa);
        for (entries, 0..) |e, i| {
            if (!e.reading.eql(reading)) continue;
            if (!e.hashed) continue;
            const strategy = e.strategy.?;
            const pair: Table.Pair = .{ .key = strategy.literal, .index = @intCast(i) };
            switch (strategy.kind) {
                .exact => try exact.append(gpa, pair),
                .starts => try prefix.append(gpa, pair),
                .ends => try extension.append(gpa, .{ .key = strategy.literal[1..], .index = pair.index }),
                .tail => {
                    const seps = std.mem.countScalar(u8, strategy.literal, strategy_mod.separatorByte(reading));
                    if (seps == 0) try basename.append(gpa, pair) else try suffix.append(gpa, .{ .components = seps + 1, .pair = pair });
                },
                .starts_component => try component.append(gpa, pair),
                .basename_starts, .within => unreachable,
            }
        }
        s.exact = try .build(gpa, reading, exact.items);
        s.basename = try .build(gpa, reading, basename.items);
        s.extension = try .build(gpa, reading, extension.items);
        s.prefix = try .build(gpa, reading, prefix.items);
        s.component_prefix = try .build(gpa, reading, component.items);
        s.component_sorted = try sortedKeys(gpa, s.component_prefix);
        // Suffixes grouped by their length in components.
        std.mem.sortUnstable(@TypeOf(suffix.items[0]), suffix.items, {}, struct {
            fn less(_: void, a: @TypeOf(suffix.items[0]), b: @TypeOf(suffix.items[0])) bool {
                return a.components < b.components;
            }
        }.less);
        var groups: std.ArrayList(Suffixes) = .empty;
        defer groups.deinit(gpa);
        errdefer for (groups.items) |*g| g.table.deinit(gpa);
        var pairs: std.ArrayList(Table.Pair) = .empty;
        defer pairs.deinit(gpa);
        var i: usize = 0;
        while (i < suffix.items.len) {
            pairs.clearRetainingCapacity();
            var j = i;
            while (j < suffix.items.len and suffix.items[j].components == suffix.items[i].components) : (j += 1)
                try pairs.append(gpa, suffix.items[j].pair);
            try groups.append(gpa, .{ .components = suffix.items[i].components, .table = try .build(gpa, reading, pairs.items) });
            i = j;
        }
        s.suffixes = try groups.toOwnedSlice(gpa);
        s.exact_sorted = try sortedKeys(gpa, s.exact);
        s.prefix_sorted = try sortedKeys(gpa, s.prefix);
        return s;
    }

    pub fn deinit(s: *Strategies, gpa: Allocator) void {
        s.exact.deinit(gpa);
        s.basename.deinit(gpa);
        s.extension.deinit(gpa);
        s.prefix.deinit(gpa);
        s.component_prefix.deinit(gpa);
        gpa.free(s.component_sorted);
        for (s.suffixes) |*g| g.table.deinit(gpa);
        gpa.free(s.suffixes);
        gpa.free(s.exact_sorted);
        gpa.free(s.prefix_sorted);
        s.* = undefined;
    }

    /// Offers every entry a strategy matches for the whole `subject`.
    pub fn visit(s: *const Strategies, subject: []const u8, reading: Reading, acc: anytype) void {
        if (s.component_sorted.len == 1 and s.exact.isEmpty() and s.basename.isEmpty() and s.extension.isEmpty() and s.prefix.isEmpty() and s.suffixes.len == 0) {
            const key = s.component_sorted[0];
            if (subject.len < key.len or !strategy_mod.eql(reading, subject[0..key.len], key)) return;
            if (reading.separator != null and std.mem.findScalar(u8, subject[key.len..], strategy_mod.separatorByte(reading)) != null) return;
            for (s.component_prefix.slots) |slot| if (slot.run != Table.empty_run) {
                acc.offerRun(s.component_prefix.runs[slot.run..][0..slot.run_len]);
                return;
            };
            unreachable; // unreachable: one sorted key came from one occupied slot
        }
        var probe: Probe = .{};
        probe.feed(s, subject, subject.len, reading, acc, acc);
        probe.finish(s, subject, subject.len, reading, acc);
    }

    /// Whether a strategy could match below `dir` (`""` is the root). In
    /// text mode the subject is `dir` then anything.
    pub fn leadsTo(s: *const Strategies, dir: []const u8, reading: Reading) bool {
        if (!s.basename.isEmpty() or !s.extension.isEmpty() or s.suffixes.len > 0) return true;
        const sep: ?u8 = if (reading.separator != null and dir.len > 0) strategy_mod.separatorByte(reading) else null;
        if (startsWithAny(s.exact_sorted, reading, dir, sep)) return true;
        if (startsWithAny(s.prefix_sorted, reading, dir, sep)) return true;
        if (startsWithAny(s.component_sorted, reading, dir, sep)) return true;
        const sep_byte = sep orelse return false;
        // A prefix key that `dir` and its separator start with.
        var h: u64 = 0;
        for (dir, 0..) |b, i| {
            h = roll(h, canonical(reading, b));
            if (b != sep_byte) continue;
            if (s.prefix.find(reading, h, dir[0 .. i + 1]) != null) return true;
        }
        return s.prefixWithSep(reading, roll(h, sep_byte), dir, sep_byte);
    }

    fn prefixWithSep(s: *const Strategies, reading: Reading, h: u64, dir: []const u8, sep: u8) bool {
        if (s.prefix.isEmpty()) return false;
        var slot = s.prefix.home(h);
        const t = &s.prefix;
        while (t.slots[slot].run != Table.empty_run) : (slot = (slot + 1) & (t.slots.len - 1)) {
            const x = t.slots[slot];
            if (x.hash != h or x.key_len != dir.len + 1) continue;
            const key = t.keys[x.key..][0..x.key_len];
            if (key[dir.len] == sep and strategy_mod.eql(reading, dir, key[0..dir.len])) return true;
        }
        return false;
    }
};

/// Whether some key starts with canonical `dir` and then `sep`, if any.
fn startsWithAny(sorted: []const []const u8, reading: Reading, dir: []const u8, sep: ?u8) bool {
    // The first key not below `dir ++ sep`.
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (compareWithDir(sorted[mid], reading, dir, sep) == .lt) lo = mid + 1 else hi = mid;
    }
    const n = dir.len + @intFromBool(sep != null);
    for (sorted[lo..]) |key| {
        if (key.len < n or !strategy_mod.eql(reading, dir, key[0..dir.len])) return false;
        if (sep) |x| return key[dir.len] == x;
        // In text mode over UTF-8 the key must also read as `dir`'s units
        // first: a truncated sequence at the end of `dir` is a unit of its
        // own, which a key continuing the sequence does not have.
        if (!reading.utf8 or unitBoundary(key, dir.len)) return true;
    }
    return false;
}

fn unitBoundary(bytes: []const u8, n: usize) bool {
    var at: usize = 0;
    while (at < n) at += unit.decode(true, bytes, at).len;
    return at == n;
}

fn compareWithDir(key: []const u8, reading: Reading, dir: []const u8, sep: ?u8) std.math.Order {
    const n = dir.len + @intFromBool(sep != null);
    for (0..@min(key.len, n)) |i| {
        const c = if (i < dir.len) canonical(reading, dir[i]) else sep.?;
        if (key[i] != c) return std.math.order(key[i], c);
    }
    return std.math.order(key.len, n);
}

fn sortedKeys(gpa: Allocator, t: Table) Allocator.Error![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(gpa);
    for (t.slots) |s| if (s.run != Table.empty_run) try keys.append(gpa, t.keys[s.key..][0..s.key_len]);
    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return keys.toOwnedSlice(gpa);
}

/// Hashes rolled along a subject: the whole prefix, its last component and
/// the last component's extension.
pub const Probe = struct {
    full: u64 = 0,
    component: u64 = 0,
    extension: u64 = 0,
    has_dot: bool = false,
    component_start: usize = 0,
    at: usize = 0,

    /// Rolls the hashes over `subject[at..to]`, offering prefix entries at
    /// each separator.
    pub fn feed(p: *Probe, s: *const Strategies, subject: []const u8, to: usize, reading: Reading, acc: anytype, component_acc: anytype) void {
        const sep: ?u8 = if (reading.separator) |_| strategy_mod.separatorByte(reading) else null;
        const last_sep = if (!s.component_prefix.isEmpty()) (if (sep) |c| std.mem.findScalarLast(u8, subject[0..to], c) else null) else null;
        if (p.at == 0 and last_sep == null) if (s.component_prefix.find(reading, 0, "")) |run| component_acc.offerRun(run);
        while (p.at < to) : (p.at += 1) {
            const b = subject[p.at];
            const c = canonical(reading, b);
            p.full = roll(p.full, c);
            if (!s.component_prefix.isEmpty() and (last_sep == null or p.at >= last_sep.?))
                if (s.component_prefix.find(reading, p.full, subject[0 .. p.at + 1])) |run| component_acc.offerRun(run);
            if (sep != null and b == sep.?) {
                if (s.prefix.find(reading, p.full, subject[0 .. p.at + 1])) |run| acc.offerRun(run);
                p.component = 0;
                p.extension = 0;
                p.has_dot = false;
                p.component_start = p.at + 1;
            } else if (b == '.') {
                p.component = roll(p.component, c);
                p.extension = 0;
                p.has_dot = true;
            } else {
                p.component = roll(p.component, c);
                p.extension = roll(p.extension, c);
            }
        }
    }

    /// Offers the entries the prefix `subject[0..end]` matches as a whole,
    /// with the hashes fed up to `end`.
    pub fn finish(p: *const Probe, s: *const Strategies, subject: []const u8, end: usize, reading: Reading, acc: anytype) void {
        const prefix = subject[0..end];
        if (s.exact.find(reading, p.full, prefix)) |run| acc.offerRun(run);
        const component = prefix[p.component_start..];
        if (s.basename.find(reading, p.component, component)) |run| acc.offerRun(run);
        if (p.has_dot) {
            const dot = std.mem.findScalarLast(u8, component, '.').?;
            if (s.extension.find(reading, p.extension, component[dot + 1 ..])) |run| acc.offerRun(run);
        }
        if (s.suffixes.len == 0) return;
        const sep = strategy_mod.separatorByte(reading);
        for (s.suffixes) |group| {
            // The last `components` components, when the prefix has them.
            var pos = prefix.len;
            var start: ?usize = null;
            for (0..group.components) |i| {
                const last = i + 1 == group.components;
                if (std.mem.findScalarLast(u8, prefix[0..pos], sep)) |j| {
                    if (last) start = j + 1 else pos = j;
                } else {
                    if (last) start = 0;
                    break;
                }
            }
            const tail = prefix[start orelse continue ..];
            if (group.table.find(reading, hashOf(reading, tail), tail)) |run| acc.offerRun(run);
        }
    }
};
