//! NFC over valid scalars; malformed bytes are distinct barriers. No heap,
//! recursion, stream-safe truncation or limit on a combining sequence.
//! Ordering uses at most 255 stable passes over each segment, O(n).
// aegis: no-danger: docs/design.md#safety-boundaries; scalar codes, combining classes and source cursors have separate fields and are bounded by Unicode data or the borrowed slice.
const std = @import("std");
const data = @import("composition.zig");
const unit = @import("unit.zig");

pub fn combining(code: u21) u8 {
    if (code < 0x300) return 0;
    var lo: usize = 0;
    var hi = data.marks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const m = data.marks[mid];
        if (m.code < code) lo = mid + 1 else if (m.code > code) hi = mid else return m.class;
    }
    return 0;
}
pub fn compose(a: u21, b: u21) ?u21 {
    if (a < 0x80 and b < 0x300) return null;
    if (a >= 0x1100 and a < 0x1113 and b >= 0x1161 and b < 0x1176) return 0xac00 + (a - 0x1100) * 588 + (b - 0x1161) * 28;
    if (a >= 0xac00 and a < 0xd7a4 and (a - 0xac00) % 28 == 0 and b > 0x11a7 and b < 0x11c3) return a + b - 0x11a7;
    var lo: usize = 0;
    var hi = data.pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const p = data.pairs[mid];
        if (p.first < a or (p.first == a and p.second < b)) lo = mid + 1 else if (p.first > a or (p.first == a and p.second > b)) hi = mid else return p.result;
    }
    return null;
}
const Raw = struct {
    bytes: []const u8,
    escaped: bool,
    at: usize = 0,
    pending: [4]u21 = @splat(0),
    index: u3 = 0,
    len: u3 = 0,
    fn next(r: *Raw) ?u21 {
        if (r.index < r.len) {
            const cp = r.pending[r.index];
            r.index += 1;
            return cp;
        }
        if (r.at == r.bytes.len) return null;
        if (r.escaped and r.bytes[r.at] == '\\' and r.at + 1 < r.bytes.len) r.at += 1;
        const u = unit.decode(true, r.bytes, r.at);
        r.at += u.len;
        r.index = 0;
        r.len = 0;
        if (u.code >= 0xac00 and u.code < 0xd7a4) {
            const s = u.code - 0xac00;
            r.pending = .{ 0x1100 + s / 588, 0x1161 + (s % 588) / 28, 0x11a7 + s % 28, 0 };
            r.len = if (s % 28 == 0) 2 else 3;
        } else if (u.code >= 0x80 and u.code < unit.ill_formed) {
            var lo: usize = 0;
            var hi = data.decompositions.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const d = data.decompositions[mid];
                if (d.code < u.code) lo = mid + 1 else if (d.code > u.code) hi = mid else {
                    r.pending = d.values;
                    r.len = d.len;
                    break;
                }
            }
        }
        if (r.len == 0) return u.code;
        r.index = 1;
        return r.pending[0];
    }
    fn eql(a: Raw, b: Raw) bool {
        return a.at == b.at and a.index == b.index and a.len == b.len;
    }
    fn offset(r: Raw) usize {
        return r.at;
    }
};
const Ordered = struct {
    first: Raw,
    end: Raw,
    cursor: Raw,
    present: std.bit_set.Static(256) = .empty,
    class: u8 = 0,
    fn init(first: Raw, end: Raw) Ordered {
        var o: Ordered = .{ .first = first, .end = end, .cursor = first };
        var r = first;
        while (!Raw.eql(r, end)) {
            const cp = r.next().?;
            o.present.set(combining(cp));
        }
        if (o.present.findFirstSet()) |c| o.class = @intCast(c);
        return o;
    }
    pub fn next(o: *Ordered) ?u21 {
        while (o.present.count() != 0) {
            while (!Raw.eql(o.cursor, o.end)) {
                const cp = o.cursor.next().?;
                if (combining(cp) == o.class) return cp;
            }
            o.present.unset(o.class);
            const c = o.present.findFirstSet() orelse return null;
            o.class = @intCast(c);
            o.cursor = o.first;
        }
        return null;
    }
};
/// Yields composed scalars and retains original byte offsets. A reordered
/// segment shares its original end offset; offsets never cut a composition.
pub const Iterator = struct {
    raw: Raw,
    at: usize = 0,
    ordered: ?Ordered = null,
    starter: ?u21 = null,
    last_class: u8 = 0,
    pub fn init(bytes: []const u8, escaped: bool) Iterator {
        return .{ .raw = .{ .bytes = bytes, .escaped = escaped } };
    }
    pub fn next(it: *Iterator) ?u21 {
        if (it.ordered) |*o| {
            while (o.next()) |cp| {
                const cc = combining(cp);
                if (it.starter) |s| if (it.last_class == 0 or it.last_class < cc) {
                    if (compose(s, cp)) |composed| {
                        it.starter = composed;
                        continue;
                    }
                };
                it.last_class = cc;
                return cp;
            }
            it.ordered = null;
        }
        if (it.raw.index == it.raw.len and it.raw.at < it.raw.bytes.len and !it.raw.escaped) {
            const pos = it.raw.at;
            if (it.raw.bytes[pos] < 0x80 and (pos + 1 == it.raw.bytes.len or it.raw.bytes[pos + 1] < 0x80)) {
                it.raw.at += 1;
                it.at = it.raw.at;
                return it.raw.bytes[pos];
            }
        }
        var before = it.raw;
        const first = it.raw.next() orelse return null;
        var starter: ?u21 = if (combining(first) == 0) first else null;
        var marks = if (starter != null) it.raw else before;
        while (true) {
            var end = it.raw;
            while (true) {
                before = end;
                const cp = end.next() orelse break;
                if (combining(cp) == 0) {
                    end = before;
                    break;
                }
            }
            const ordered = Ordered.init(marks, end);
            var pass = ordered;
            var last: u8 = 0;
            var remaining = false;
            const original = starter;
            while (pass.next()) |cp| {
                const cc = combining(cp);
                if (starter) |s| if (last == 0 or last < cc) {
                    if (compose(s, cp)) |joined| {
                        starter = joined;
                        continue;
                    }
                };
                last = cc;
                remaining = true;
            }
            var following = end;
            if (!remaining and starter != null) if (following.next()) |cp| if (compose(starter.?, cp)) |joined| {
                starter = joined;
                it.raw = following;
                marks = following;
                continue;
            };
            it.raw = end;
            it.at = end.offset();
            it.ordered = ordered;
            it.starter = original;
            it.last_class = 0;
            if (starter) |s| return s;
            const cp = it.ordered.?.next().?;
            it.last_class = combining(cp);
            return cp;
        }
    }
};
