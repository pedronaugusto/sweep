//! NFC over valid scalars; malformed bytes are distinct barriers. No heap,
//! recursion, stream-safe truncation or limit on a combining sequence.
//! Ordering uses at most 255 stable passes over each segment, O(n). The
//! Unicode data (combining classes, canonical decompositions and primary
//! composites) is xenoglyph's; the iteration, which keeps original byte
//! offsets and malformed bytes, is sweep's.
const std = @import("std");
const aegis = @import("aegis");
const xenoglyph = @import("xenoglyph");
const unit = @import("unit.zig");

/// Canonical_Combining_Class; a malformed byte's code is a starter.
pub fn combining(code: u21) u8 {
    if (code < 0x300) return 0;
    return xenoglyph.normalize.combiningClass(code);
}
/// The primary composite of `a` and `b`, if there is one.
pub fn compose(a: u21, b: u21) ?u21 {
    if (a < 0x80 and b < 0x300) return null;
    if (a >= unit.ill_formed or b >= unit.ill_formed) return null;
    return xenoglyph.normalize.compose(a, b);
}

/// The scalars of a text as written, before composition: the type of an
/// iterator's private `raw`.
pub const Raw = struct {
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
        if (u.code >= 0x80 and u.code < unit.ill_formed) {
            var buffer: [18]u21 = undefined;
            const d = xenoglyph.normalize.decompose(u.code, .nfd, &buffer);
            if (d.len > r.pending.len) aegis.assert.never("a canonical decomposition is at most four scalars");
            if (d.len > 1 or d[0] != u.code) {
                @memcpy(r.pending[0..d.len], d);
                r.len = @intCast(d.len);
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
pub const Ordered = struct {
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
/// A text's composed scalars, a backslash one like any other: the public `sweep.Composed`.
/// `at` is the byte offset after the last scalar `next` returned.
pub const Composed = struct {
    inner: Iterator,
    at: usize = 0,

    pub fn init(text: []const u8) Composed {
        return .{ .inner = .init(text, false) };
    }

    pub fn next(c: *Composed) ?u21 {
        const cp = c.inner.next();
        c.at = c.inner.at;
        return cp;
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
    /// `escaped` is the parser's: a backslash quotes the byte after it, as the pattern's syntax says.
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
