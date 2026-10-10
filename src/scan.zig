//! A handful of entries decided one at a time, in insertion order: each by
//! its literal comparison, or read straight from its text. A query pays for
//! the entries, not for the subject's length, and leaves at the first
//! answer it needs. Past `max_entries` the hashed strategies and the lazy
//! DFA win and a part uses them instead.
const std = @import("std");
const program_mod = @import("program.zig");
const strategy_mod = @import("strategy.zig");
const direct = @import("direct.zig");

const Allocator = std.mem.Allocator;
const Strategy = strategy_mod.Strategy;

/// Most entries of one reading that are scanned. Past it, a pass over the
/// subject (a rolling hash and a DFA step per byte, about the cost of
/// scanning twenty entries) is cheaper than asking every entry.
pub const max_entries = 32;

/// How one entry is decided.
const How = union(enum) {
    /// By comparing bytes.
    literal: Strategy,
    /// By reading its text, which `source` borrows from the scan's bytes.
    text: struct { source: []const u8, compiled: direct.Compiled },
};

const Member = struct {
    /// The entry's place in the set.
    index: u32,
    how: How,
};

/// The entries of one reading, scanned.
pub const Scan = struct {
    reading: program_mod.Reading,
    members: []Member,
    /// Literals and sources, in one allocation.
    bytes: []u8,

    /// The scan of the entries of `reading`, or null when there are more
    /// than `max_entries` or one needs the automaton: only a literal
    /// strategy or a plain byte pattern is scanned.
    pub fn build(gpa: Allocator, entries: anytype, reading: program_mod.Reading) Allocator.Error!?Scan {
        var count: usize = 0;
        var size: usize = 0;
        for (entries) |e| {
            if (!e.reading.eql(reading)) continue;
            count += 1;
            if (count > max_entries) return null;
            if (e.strategy) |s| {
                size += s.literal.len;
            } else if (decide(e)) |_| {
                size += e.pattern.len;
            } else return null;
        }
        const members = try gpa.alloc(Member, count);
        errdefer gpa.free(members);
        const bytes = try gpa.alloc(u8, size);
        var at: usize = 0;
        var n: usize = 0;
        for (entries, 0..) |e, index| {
            if (!e.reading.eql(reading)) continue;
            const how: How = if (e.strategy) |s| literal: {
                @memcpy(bytes[at..][0..s.literal.len], s.literal);
                at += s.literal.len;
                break :literal .{ .literal = .{ .kind = s.kind, .literal = bytes[at - s.literal.len .. at] } };
            } else text: {
                @memcpy(bytes[at..][0..e.pattern.len], e.pattern);
                at += e.pattern.len;
                break :text .{ .text = .{ .source = bytes[at - e.pattern.len .. at], .compiled = decide(e).? } };
            };
            // safe: the set counted its entries against max_entries.
            members[n] = .{ .index = @intCast(index), .how = how };
            n += 1;
        }
        return .{ .reading = reading, .members = members, .bytes = bytes };
    }

    pub fn deinit(s: *Scan, gpa: Allocator) void {
        gpa.free(s.members);
        gpa.free(s.bytes);
        s.* = undefined;
    }

    fn decide(e: anytype) ?direct.Compiled {
        return direct.Compiled.init(e.pattern, e.entry.options, e.pattern.len, .{ .units = e.pattern.len, .brackets = e.pattern.len });
    }

    /// Offers the entries that match all of `subject` and count for the
    /// accumulator's kind, stopping where its mode has what it needs.
    pub fn visit(s: *const Scan, subject: []const u8, acc: anytype) void {
        if (acc.mode == .last) {
            var i = s.members.len;
            while (i > 0) {
                i -= 1;
                if (s.offers(s.members[i], subject, acc)) return;
            }
        } else for (s.members) |m| {
            if (s.offers(m, subject, acc) and acc.mode != .all) return;
        }
    }

    fn offers(s: *const Scan, m: Member, subject: []const u8, acc: anytype) bool {
        if (!acc.counts(m.index)) return false;
        const hit = switch (m.how) {
            .literal => |strategy| strategy.matches(s.reading, subject),
            .text => |text| text.compiled.matches(text.source, subject),
        };
        if (hit) acc.offer(m.index);
        return hit;
    }
};
