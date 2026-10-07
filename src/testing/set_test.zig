//! A set against a loop over its entries compiled one by one: `any`,
//! `first`, `last`, `all`, `ancestors` and `leadsTo`, with `dir_only` and
//! both kinds of subject.
const std = @import("std");
const sweep = @import("../sweep.zig");
const gen = @import("gen.zig");

// The property loops build thousands of patterns; the testing allocator's
// bookkeeping would dominate them. Leaks and failures are allocation_test's.
const gpa = std.heap.smp_allocator;
const Set = sweep.Set;
const Pattern = sweep.Pattern;

/// Entries and their patterns compiled alone.
const Fixture = struct {
    set: Set,
    patterns: std.ArrayList(Pattern) = .empty,
    dir_only: std.ArrayList(bool) = .empty,
    /// Each entry's pattern and options, for a failure's report.
    texts: std.ArrayList(u8) = .empty,

    fn deinit(f: *Fixture) void {
        for (f.patterns.items) |*p| p.deinit();
        f.patterns.deinit(gpa);
        f.dir_only.deinit(gpa);
        f.texts.deinit(gpa);
        f.set.deinit();
        f.* = undefined;
    }

    fn matches(f: *const Fixture, index: usize, subject: []const u8, kind: sweep.Kind) bool {
        if (f.dir_only.items[index] and kind == .file) return false;
        return f.patterns.items[index].matches(subject);
    }
};

fn fixture(s: gen.Source, count: usize, pieces: []const []const u8) !Fixture {
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    var patterns: std.ArrayList(Pattern) = .empty;
    errdefer {
        for (patterns.items) |*p| p.deinit();
        patterns.deinit(gpa);
    }
    var dir_only: std.ArrayList(bool) = .empty;
    errdefer dir_only.deinit(gpa);
    var texts: std.ArrayList(u8) = .empty;
    errdefer texts.deinit(gpa);
    // One separator for the whole set.
    const first = gen.options(s);
    for (0..count) |_| {
        var buf: [16]u8 = undefined;
        var options = gen.options(s);
        options.syntax.separator = first.syntax.separator;
        const pattern = gen.string(s, &buf, pieces);
        const entry: Set.Entry = .{ .options = options, .dir_only = s.oneIn(4) };
        const index = builder.add(pattern, entry) catch |err| switch (err) {
            error.InvalidPattern => continue,
            else => return err,
        };
        try std.testing.expectEqual(patterns.items.len, index);
        try patterns.append(gpa, try .compile(gpa, pattern, options));
        try dir_only.append(gpa, entry.dir_only);
        try texts.print(gpa, "  {d}: \"{f}\" {any} dir_only={}\n", .{ index, std.zig.fmtString(pattern), options, entry.dir_only });
    }
    return .{ .set = try builder.build(), .patterns = patterns, .dir_only = dir_only, .texts = texts };
}

fn queriesOne(s: gen.Source) anyerror!void {
    var f = try fixture(s, 1 + s.index(8), &gen.any_pattern);
    defer f.deinit();
    var cache: Set.Cache = try .init(gpa, &f.set, .{ .capacity = if (s.oneIn(2)) 0 else 1 << 17 });
    defer cache.deinit();
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(gpa);
    for (0..4) |_| {
        var text_buf: [16]u8 = undefined;
        const text = gen.string(s, &text_buf, &gen.any_text);
        const kind: sweep.Kind = if (s.value(bool)) .dir else .file;
        var want_first: ?u32 = null;
        var want_last: ?u32 = null;
        var want_all: std.ArrayList(u32) = .empty;
        defer want_all.deinit(gpa);
        for (0..f.patterns.items.len) |i| if (f.matches(i, text, kind)) {
            if (want_first == null) want_first = @intCast(i);
            want_last = @intCast(i);
            try want_all.append(gpa, @intCast(i));
        };
        out.clearRetainingCapacity();
        try f.set.all(gpa, &cache, text, kind, &out);
        const ok = f.set.any(&cache, text, kind) == (want_first != null) and
            f.set.first(&cache, text, kind) == want_first and
            f.set.last(&cache, text, kind) == want_last and
            std.mem.eql(u32, out.items, want_all.items);
        if (!ok) {
            std.debug.print("set vs \"{f}\" ({t}): want {any}, all {any}, first {?}, last {?}\n", .{ std.zig.fmtString(text), kind, want_all.items, out.items, f.set.first(&cache, text, kind), f.set.last(&cache, text, kind) });
            std.debug.print("{s}", .{f.texts.items});
            return error.TestUnexpectedResult;
        }
        try ancestorsAgree(&f, &cache, text, kind);
    }
}

fn ancestorsAgree(f: *const Fixture, cache: *Set.Cache, text: []const u8, kind: sweep.Kind) !void {
    var it = f.set.ancestors(cache, text, kind);
    var at: usize = 0;
    const sep = if (f.set.parts.len > 0) f.set.separator else null;
    while (true) {
        const end = if (sep) |x| std.mem.findScalarPos(u8, text, at, x) orelse text.len else text.len;
        const whole = end == text.len;
        const prefix = text[0..end];
        const step_kind: sweep.Kind = if (whole) kind else .dir;
        var want_last: ?u32 = null;
        var want_leads = false;
        for (f.patterns.items, 0..) |*p, i| {
            if (f.matches(i, prefix, step_kind)) want_last = @intCast(i);
            if (p.leadsTo(prefix)) want_leads = true;
        }
        const step = it.next() orelse return error.TestUnexpectedResult;
        if (step.end != end or step.last != want_last or step.leads != want_leads) {
            std.debug.print("ancestors of \"{f}\" at {d}: want last {?} leads {}, got end {d} last {?} leads {}\n", .{ std.zig.fmtString(text), end, want_last, want_leads, step.end, step.last, step.leads });
            std.debug.print("{s}", .{f.texts.items});
            return error.TestUnexpectedResult;
        }
        // leadsTo on its own agrees with the pass.
        try std.testing.expectEqual(want_leads, f.set.leadsTo(cache, prefix));
        if (whole) break;
        at = end + 1;
    }
    try std.testing.expect(it.next() == null);
}

test "fuzz: a set equals its entries one by one" {
    try std.testing.fuzz({}, gen.fuzzed(queriesOne), .{});
}

test "a set equals its entries one by one on seeded inputs" {
    try gen.seeded(queriesOne, 0x5e7_5e7, 1500);
}

/// gitignore-shaped entries, where every strategy applies.
const ignore_pieces = [_][]const u8{ "a", "b", "/", "*", "**/", "/**", ".", "c", "*.c", "x", "a/b", "?" };

fn strategiesOne(s: gen.Source) anyerror!void {
    var f = try fixture(s, 1 + s.index(12), &ignore_pieces);
    defer f.deinit();
    var cache: Set.Cache = try .init(gpa, &f.set, .{ .capacity = 1 << 16 });
    defer cache.deinit();
    for (0..6) |_| {
        var text_buf: [16]u8 = undefined;
        const text = gen.string(s, &text_buf, &[_][]const u8{ "a", "b", "/", ".", "c", "x", "A", ".c" });
        const kind: sweep.Kind = if (s.value(bool)) .dir else .file;
        var want_last: ?u32 = null;
        for (0..f.patterns.items.len) |i| if (f.matches(i, text, kind)) {
            want_last = @intCast(i);
        };
        if (f.set.last(&cache, text, kind) != want_last) {
            std.debug.print("strategies vs \"{f}\": want {?}, got {?}\n", .{ std.zig.fmtString(text), want_last, f.set.last(&cache, text, kind) });
            return error.TestUnexpectedResult;
        }
        try ancestorsAgree(&f, &cache, text, kind);
    }
}

test "hashed strategies equal the automaton on seeded inputs" {
    try gen.seeded(strategiesOne, 0x57_4a7, 2000);
}

test "gitignore lines through a set: the last match decides" {
    const lines = [_][]const u8{ "*.log", "!keep.log", "build/", "/root.txt", "doc/**/*.md", "# comment", "" };
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    var negated: [lines.len]bool = undefined;
    for (lines) |line| {
        const parsed = sweep.gitignore.parseLine(line) orelse continue;
        const index = try builder.add(parsed.pattern, parsed.entry);
        negated[index] = parsed.negated;
    }
    var set = try builder.build();
    defer set.deinit();
    var cache: Set.Cache = try .init(gpa, &set, .{});
    defer cache.deinit();
    const Case = struct { path: []const u8, kind: sweep.Kind, ignored: bool };
    const cases = [_]Case{
        .{ .path = "a.log", .kind = .file, .ignored = true },
        .{ .path = "x/y/a.log", .kind = .file, .ignored = true },
        .{ .path = "x/keep.log", .kind = .file, .ignored = false },
        .{ .path = "build", .kind = .dir, .ignored = true },
        .{ .path = "build", .kind = .file, .ignored = false },
        .{ .path = "src/build", .kind = .dir, .ignored = true },
        .{ .path = "root.txt", .kind = .file, .ignored = true },
        .{ .path = "x/root.txt", .kind = .file, .ignored = false },
        .{ .path = "doc/a/b.md", .kind = .file, .ignored = true },
        .{ .path = "doc/b.md", .kind = .file, .ignored = true },
        .{ .path = "src/doc/b.md", .kind = .file, .ignored = false },
    };
    for (cases) |case| {
        const ignored = if (set.last(&cache, case.path, case.kind)) |i| !negated[i] else false;
        try std.testing.expectEqual(case.ignored, ignored);
    }
    // A file below an ignored directory: the parent decides first.
    var it = set.ancestors(&cache, "build/x/keep.log", .file);
    const top = it.next().?;
    try std.testing.expectEqual(@as(usize, 5), top.end);
    try std.testing.expect(top.last != null and !negated[top.last.?]);
}

test "a set whose cache keeps clearing still answers within the bound" {
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    var patterns: std.ArrayList(Pattern) = .empty;
    defer {
        for (patterns.items) |*p| p.deinit();
        patterns.deinit(gpa);
    }
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var buf: [32]u8 = undefined;
    for (0..1000) |i| {
        // Stars between letters, so the states multiply.
        var len: usize = 0;
        for (0..1 + r.uintLessThan(usize, 6)) |_| {
            buf[len] = '*';
            buf[len + 1] = "abcd"[r.uintLessThan(usize, 4)];
            len += 2;
        }
        buf[len] = "xyz"[i % 3];
        len += 1;
        _ = try builder.add(buf[0..len], .{});
        try patterns.append(gpa, try .compile(gpa, buf[0..len], .{}));
    }
    var set = try builder.build();
    defer set.deinit();
    var cache: Set.Cache = try .init(gpa, &set, .{ .capacity = 0 });
    defer cache.deinit();
    const subjects = [_][]const u8{ "abcdabcdabcdabcdx", gen.repeat("aaaabbbbccccdddd", 4) ++ "y", gen.repeat("dcbadcbadcba", 8) ++ "z" };
    for (subjects) |subject| {
        var want: ?u32 = null;
        for (patterns.items, 0..) |*p, i| if (p.matches(subject)) {
            want = @intCast(i);
        };
        try std.testing.expectEqual(want, set.last(&cache, subject, .file));
    }
    try std.testing.expect(cache.stats().clears > 0);
}

test "eight threads share one set, each with its own cache" {
    var builder: Set.Builder = .init(gpa);
    defer builder.deinit();
    const lines = [_][]const u8{ "*.o", "build/**", "src/**/test_*.zig", "**/node_modules", "*.{c,h}", "a?c/*" };
    for (lines) |line| _ = try builder.add(line, .{ .options = .{ .syntax = .glob, .anywhere = true } });
    var set = try builder.build();
    defer set.deinit();
    const Worker = struct {
        fn run(s: *const Set, failed: *std.atomic.Value(bool)) void {
            var cache = Set.Cache.init(std.heap.page_allocator, s, .{ .capacity = 1 << 16 }) catch return failed.store(true, .monotonic);
            defer cache.deinit();
            const subjects = [_]struct { []const u8, ?u32 }{
                .{ "x/y/z.o", 0 },        .{ "build/a/b", 1 }, .{ "src/a/test_b.zig", 2 },
                .{ "q/node_modules", 3 }, .{ "lib/x.h", 4 },   .{ "abc/d", 5 },
                .{ "nothing", null },
            };
            for (0..2000) |_| for (subjects) |case| {
                if (s.last(&cache, case[0], .file) != case[1]) failed.store(true, .monotonic);
            };
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &set, &failed });
    for (threads) |t| t.join();
    try std.testing.expect(!failed.load(.monotonic));
}
