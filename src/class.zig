//! Bracket classes: the set of units one bracket expression matches.
//!
//! A class holds a bitset for the codes below 256 and sorted, disjoint,
//! inclusive ranges for the codes above, kept in a table the program owns.
//! Membership is decided for the canonical unit: the subject's unit after
//! case folding, so a folding class only needs its lower-case letters.
const std = @import("std");
const unit = @import("unit.zig");
const syntax = @import("syntax.zig");

const Code = unit.Code;

/// The highest code a unit can have: the last ill-formed byte.
pub const max_code: Code = unit.ill_formed + 0xff;

/// One class of a program.
pub const Class = struct {
    /// Codes 0 to 255, one bit each.
    low: [4]u64 = @splat(0),
    /// The first of this class's ranges in the program's range table.
    first: u32 = 0,
    /// How many ranges the class has; all are above 255.
    count: u32 = 0,

    /// Whether `code` is in the class. `ranges` is the program's table.
    pub fn contains(class: *const Class, ranges: []const Range, code: Code) bool {
        if (code < 256) return class.hasLow(@intCast(code));
        var lo: usize = class.first;
        var hi: usize = class.first + class.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const range = ranges[mid];
            if (code < range.lo) {
                hi = mid;
            } else if (code > range.hi) {
                lo = mid + 1;
            } else return true;
        }
        return false;
    }

    pub fn hasLow(class: *const Class, byte: u8) bool {
        return class.low[byte >> 6] >> @intCast(byte & 63) & 1 != 0;
    }

    pub fn setLow(class: *Class, byte: u8) void {
        class.low[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
    }

    pub fn clearLow(class: *Class, byte: u8) void {
        class.low[byte >> 6] &= ~(@as(u64, 1) << @intCast(byte & 63));
    }

    /// Whether the class holds any code at all.
    pub fn isEmpty(class: *const Class) bool {
        return class.count == 0 and std.mem.allEqual(u64, &class.low, 0);
    }
};

/// Codes `lo` to `hi`, both included.
pub const Range = struct {
    lo: Code,
    hi: Code,
};

/// The POSIX classes git knows, all ASCII-only.
pub const Posix = enum {
    alnum,
    alpha,
    blank,
    cntrl,
    digit,
    graph,
    lower,
    print,
    punct,
    space,
    upper,
    xdigit,

    /// The class `name` spells, or null for a name git does not know.
    pub fn named(name: []const u8) ?Posix {
        return std.meta.stringToEnum(Posix, name);
    }

    /// Whether ASCII code `c` is in the class. `git_fold` is git's
    /// `WM_CASEFOLD` rule that `[:upper:]` also takes lower case.
    pub fn has(posix: Posix, c: u8, git_fold: bool) bool {
        return switch (posix) {
            .alnum => std.ascii.isAlphanumeric(c),
            .alpha => std.ascii.isAlphabetic(c),
            .blank => c == ' ' or c == '\t',
            .cntrl => c < 0x20 or c == 0x7f,
            .digit => std.ascii.isDigit(c),
            .graph => c > 0x20 and c < 0x7f,
            .lower => std.ascii.isLower(c),
            .print => c >= 0x20 and c < 0x7f,
            .punct => c > 0x20 and c < 0x7f and !std.ascii.isAlphanumeric(c),
            .space => c == ' ' or (c >= '\t' and c <= '\r'),
            .upper => std.ascii.isUpper(c) or (git_fold and std.ascii.isLower(c)),
            .xdigit => std.ascii.isHex(c),
        };
    }
};

/// Fills one class from bracket members as the parser reads them, by the
/// dialect's membership rule for each canonical code.
pub const Filler = struct {
    class: Class,
    /// The table the class's ranges go into, from `class.first` on.
    ranges: []Range,
    case: syntax.Case,
    /// Whether the table ran out of room.
    overflow: bool = false,

    pub fn init(ranges: []Range, first: u32, case: syntax.Case) Filler {
        return .{ .class = .{ .first = first }, .ranges = ranges, .case = case };
    }

    /// A single member, as written.
    pub fn single(f: *Filler, member: Code) void {
        if (member < 256) {
            const byte: u8 = @intCast(member);
            switch (f.case) {
                // A folded subject never holds an upper-case letter, so a
                // `.ascii` member counts for its lower-case form; the
                // `.ascii_git` member compares unfolded and so never meets
                // an upper-case letter at all.
                .ascii => f.class.setLow(std.ascii.toLower(byte)),
                .sensitive, .ascii_git => f.class.setLow(byte),
            }
        } else f.addRange(member, member);
    }

    /// A range member `lo-hi`, as written.
    pub fn range(f: *Filler, lo: Code, hi: Code) void {
        if (lo > hi) return;
        if (lo < 256) {
            const top: u8 = @intCast(@min(hi, 255));
            var c: u16 = @intCast(lo);
            while (c <= top) : (c += 1) {
                const byte: u8 = @intCast(c);
                switch (f.case) {
                    .sensitive => f.class.setLow(byte),
                    // Either case of a letter in the range matches.
                    .ascii => f.class.setLow(std.ascii.toLower(byte)),
                    // git retries a lower-case text byte as upper case.
                    .ascii_git => {
                        f.class.setLow(byte);
                        if (std.ascii.isUpper(byte)) f.class.setLow(std.ascii.toLower(byte));
                    },
                }
            }
        }
        if (hi >= 256) f.addRange(@max(lo, 256), hi);
    }

    /// A `[:name:]` member.
    pub fn posix(f: *Filler, class: Posix) void {
        for (0..128) |c| {
            const byte: u8 = @intCast(c);
            const in = switch (f.case) {
                .sensitive => class.has(byte, false),
                .ascii => class.has(byte, false) or class.has(swapCase(byte), false),
                .ascii_git => class.has(byte, true),
            };
            if (in) f.class.setLow(byte);
        }
    }

    /// Ends the class: sorts and merges its ranges, applies `negated`, and
    /// takes `separator` out. Returns the finished class.
    pub fn finish(f: *Filler, negated: bool, separator: ?Code) Class {
        f.normalize();
        if (negated) f.negate();
        if (separator) |sep| f.remove(sep);
        return f.class;
    }

    fn addRange(f: *Filler, lo: Code, hi: Code) void {
        const at = f.class.first + f.class.count;
        if (at >= f.ranges.len) {
            f.overflow = true;
            return;
        }
        f.ranges[at] = .{ .lo = lo, .hi = hi };
        f.class.count += 1;
    }

    fn mine(f: *Filler) []Range {
        return f.ranges[f.class.first..][0..f.class.count];
    }

    fn normalize(f: *Filler) void {
        const list = f.mine();
        std.mem.sortUnstable(Range, list, {}, struct {
            fn less(_: void, a: Range, b: Range) bool {
                return a.lo < b.lo;
            }
        }.less);
        var out: usize = 0;
        for (list) |r| {
            if (out > 0 and r.lo <= list[out - 1].hi +| 1) {
                list[out - 1].hi = @max(list[out - 1].hi, r.hi);
            } else {
                list[out] = r;
                out += 1;
            }
        }
        f.class.count = @intCast(out);
    }

    fn negate(f: *Filler) void {
        for (&f.class.low) |*word| word.* = ~word.*;
        // The complement of k sorted ranges within 256..max_code has at most
        // k + 1 ranges; the gaps are written over the table from the front.
        const count = f.class.count;
        var next: Code = 256;
        var out: usize = 0;
        var i: usize = 0;
        // Each gap ends before range i starts, and range i is read before
        // gap i overwrites it, so walking forwards is safe.
        while (i < count) : (i += 1) {
            const r = f.ranges[f.class.first + i];
            if (r.lo > next) {
                f.ranges[f.class.first + out] = .{ .lo = next, .hi = r.lo - 1 };
                out += 1;
            }
            next = r.hi + 1;
        }
        if (next <= max_code) {
            const at = f.class.first + out;
            if (at >= f.ranges.len) {
                f.overflow = true;
            } else {
                f.ranges[at] = .{ .lo = next, .hi = max_code };
                out += 1;
            }
        }
        f.class.count = @intCast(out);
    }

    fn remove(f: *Filler, code: Code) void {
        if (code < 256) {
            f.class.clearLow(@intCast(code));
            return;
        }
        // A separator above 255 is an ill-formed byte's code; split the
        // range that holds it.
        const list = f.mine();
        for (list, 0..) |r, i| {
            if (code < r.lo or code > r.hi) continue;
            if (r.lo == r.hi) {
                @memmove(list[i .. list.len - 1], list[i + 1 ..]);
                f.class.count -= 1;
            } else if (code == r.lo) {
                list[i].lo += 1;
            } else if (code == r.hi) {
                list[i].hi -= 1;
            } else {
                const at = f.class.first + f.class.count;
                if (at >= f.ranges.len) {
                    f.overflow = true;
                    return;
                }
                @memmove(f.ranges[f.class.first + i + 1 .. at + 1], f.ranges[f.class.first + i .. at]);
                f.ranges[f.class.first + i].hi = code - 1;
                f.ranges[f.class.first + i + 1].lo = code + 1;
                f.class.count += 1;
            }
            return;
        }
    }
};

fn swapCase(c: u8) u8 {
    if (std.ascii.isUpper(c)) return std.ascii.toLower(c);
    if (std.ascii.isLower(c)) return std.ascii.toUpper(c);
    return c;
}

test "negation complements both halves" {
    var table: [8]Range = undefined;
    var f: Filler = .init(&table, 0, .sensitive);
    f.single('a');
    f.single(0x1000);
    const class = f.finish(true, '/');
    try std.testing.expect(!class.contains(&table, 'a'));
    try std.testing.expect(!class.contains(&table, '/'));
    try std.testing.expect(class.contains(&table, 'b'));
    try std.testing.expect(!class.contains(&table, 0x1000));
    try std.testing.expect(class.contains(&table, 0xfff));
    try std.testing.expect(class.contains(&table, 0x1001));
    try std.testing.expect(class.contains(&table, max_code));
}

test "ranges merge and split around a separator" {
    var table: [8]Range = undefined;
    var f: Filler = .init(&table, 0, .sensitive);
    f.range(0x300, 0x400);
    f.range(0x350, 0x500);
    f.single(0x501);
    const class = f.finish(false, 0x380);
    try std.testing.expectEqual(@as(u32, 2), class.count);
    try std.testing.expect(class.contains(&table, 0x37f));
    try std.testing.expect(!class.contains(&table, 0x380));
    try std.testing.expect(class.contains(&table, 0x501));
}

test "case rules for brackets" {
    var table: [1]Range = undefined;
    var sensitive: Filler = .init(&table, 0, .ascii);
    sensitive.range('0', 'Z');
    const ascii = sensitive.finish(false, null);
    try std.testing.expect(ascii.hasLow('a'));
    try std.testing.expect(!ascii.hasLow('_'));
    var git: Filler = .init(&table, 0, .ascii_git);
    git.single('A');
    git.range('A', 'Z');
    const git_class = git.finish(false, null);
    try std.testing.expect(git_class.hasLow('q'));
    var member: Filler = .init(&table, 0, .ascii_git);
    member.single('A');
    try std.testing.expect(!member.finish(false, null).hasLow('a'));
}
