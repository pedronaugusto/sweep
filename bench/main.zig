//! sweep's own workloads, timed: `zig build bench [-- --smoke] [-- --json]`.
//!
//! - single: realistic patterns over a synthetic tree, one-shot and compiled;
//! - compile: per-pattern compile and set builds;
//! - set: `any`, `last`, `all` and an `ancestors` pass over sets of 100 to
//!   10,000 gitignore-shaped entries, with the lazy DFA's states and clears;
//! - adversarial: the shapes that make backtrackers exponential.
//!
//! Timings are wall-clock on this machine; CI only compiles this file.
const std = @import("std");
const sweep = @import("sweep");
const gen = @import("gen.zig");

const Allocator = std.mem.Allocator;

const Report = struct {
    w: *std.Io.Writer,
    json: bool,
    io: std.Io,

    fn line(r: Report, workload: []const u8, name: []const u8, metric: []const u8, value: f64, unit_name: []const u8) !void {
        if (r.json) {
            try r.w.print("{{\"workload\":\"{s}\",\"name\":\"{f}\",\"metric\":\"{s}\",\"value\":{d:.3},\"unit\":\"{s}\"}}\n", .{ workload, std.zig.fmtString(name), metric, value, unit_name });
        } else {
            try r.w.print("{s:<12} {s:<28} {s:<12} {d:>12.2} {s}\n", .{ workload, name, metric, value, unit_name });
        }
    }

    fn now(r: Report) std.Io.Timestamp {
        return std.Io.Clock.awake.now(r.io);
    }
};

fn nsBetween(start: std.Io.Timestamp, end: std.Io.Timestamp) f64 {
    return @floatFromInt(start.durationTo(end).nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var smoke = false;
    var json = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--json")) json = true else return error.UnknownArgument;
    }
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const r: Report = .{ .w = &stdout.interface, .json = json, .io = init.io };
    defer r.w.flush() catch {};

    const paths = try gen.tree(a, if (smoke) 2_000 else 100_000, 0x5eeb);
    try single(r, gpa, paths, smoke);
    try compile(r, gpa, if (smoke) 1 else 2_000);
    for (if (smoke) &[_]usize{100} else &[_]usize{ 100, 1_000, 10_000 }) |n| try sets(r, gpa, a, paths, n);
    try adversarial(r, gpa, a, smoke);
    try longPrefix(r, gpa, a, smoke);
    try longRepeated(r, gpa, a, smoke);
    try features(r, gpa, smoke);
}

fn single(r: Report, gpa: Allocator, paths: []const []const u8, smoke: bool) !void {
    // A pass is a fraction of a millisecond: each engine's row is the best
    // of several passes in a row, so a cold cache, a timer tick or the other
    // engine's last pass does not decide it.
    const passes: usize = if (smoke) 1 else 7;
    for (gen.singles) |case| {
        const options: sweep.Options = .{ .anywhere = case[1] };
        var pattern: sweep.Pattern = try .compile(gpa, case[0], options);
        defer pattern.deinit();
        var one_shot_ns: f64 = std.math.inf(f64);
        var matched: usize = 0;
        for (0..passes) |_| {
            const t = r.now();
            matched = try oneShotPass(case[0], options, paths);
            one_shot_ns = @min(one_shot_ns, nsBetween(t, r.now()));
        }
        var compiled_ns: f64 = std.math.inf(f64);
        var compiled: usize = 0;
        for (0..passes) |_| {
            const t = r.now();
            compiled = compiledPass(&pattern, paths);
            compiled_ns = @min(compiled_ns, nsBetween(t, r.now()));
        }
        if (matched != compiled) return error.EnginesDisagree;
        const count: f64 = @floatFromInt(paths.len);
        try r.line("single", case[0], "one-shot", one_shot_ns / count, "ns/path");
        try r.line("single", case[0], "compiled", compiled_ns / count, "ns/path");
        try r.line("single", case[0], "matched", @floatFromInt(matched), "paths");
    }
}

// Each timed loop has a function of its own, so how one engine's code is
// laid out never moves the other's loop.

noinline fn oneShotPass(pattern: []const u8, options: sweep.Options, paths: []const []const u8) !usize {
    var matched: usize = 0;
    for (paths) |p| matched += @intFromBool(try sweep.match(pattern, p, options));
    return matched;
}

noinline fn compiledPass(pattern: *const sweep.Pattern, paths: []const []const u8) usize {
    var matched: usize = 0;
    for (paths) |p| matched += @intFromBool(pattern.matches(p));
    return matched;
}

fn compile(r: Report, gpa: Allocator, rounds: usize) !void {
    for (gen.singles) |case| {
        const t0 = r.now();
        for (0..rounds) |_| {
            var p: sweep.Pattern = try .compile(gpa, case[0], .{ .anywhere = case[1] });
            p.deinit();
        }
        try r.line("compile", case[0], "compile", nsBetween(t0, r.now()) / @as(f64, @floatFromInt(rounds)), "ns");
    }
}

fn sets(r: Report, gpa: Allocator, a: Allocator, paths: []const []const u8, n: usize) !void {
    const entries = try gen.set(a, n, 0x5e7 + n);
    const name = try a.print("{d} entries", .{n});
    const t0 = r.now();
    var builder: sweep.Set.Builder = .init(gpa);
    defer builder.deinit();
    for (entries) |e| _ = try builder.add(e.pattern, .{ .options = .{ .anywhere = true }, .dir_only = e.dir_only });
    var set = try builder.build();
    defer set.deinit();
    try r.line("set", name, "build", nsBetween(t0, r.now()) / 1e6, "ms");
    var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
    defer cache.deinit();
    const count: f64 = @floatFromInt(paths.len);
    var hits: usize = 0;
    // The first pass builds the lazy DFA's states; the second is warm.
    for ([_][]const u8{ "any (cold)", "any" }) |label| {
        const t = r.now();
        for (paths) |p| hits += @intFromBool(set.any(&cache, p, .file));
        try r.line("set", name, label, nsBetween(t, r.now()) / count, "ns/path");
    }
    var t = r.now();
    for (paths) |p| hits += @intFromBool(set.last(&cache, p, .file) != null);
    try r.line("set", name, "last", nsBetween(t, r.now()) / count, "ns/path");
    var out: std.ArrayList(sweep.Set.Index) = .empty;
    defer out.deinit(gpa);
    t = r.now();
    for (paths) |p| {
        out.clearRetainingCapacity();
        try set.all(gpa, &cache, p, .file, &out);
        hits += out.items.len;
    }
    try r.line("set", name, "all", nsBetween(t, r.now()) / count, "ns/path");
    t = r.now();
    for (paths) |p| {
        var it = set.ancestors(&cache, p, .file);
        while (it.next()) |step| hits += @intFromBool(step.last != null);
    }
    try r.line("set", name, "ancestors", nsBetween(t, r.now()) / count, "ns/path");
    const stats = cache.stats();
    try r.line("set", name, "states", @floatFromInt(stats.states), "states");
    try r.line("set", name, "clears", @floatFromInt(stats.clears), "clears");
    std.mem.doNotOptimizeAway(hits);
}

fn adversarial(r: Report, gpa: Allocator, a: Allocator, smoke: bool) !void {
    const n: usize = if (smoke) 256 else 4096;
    const long_a = try a.alloc(u8, n);
    @memset(long_a, 'a');
    const deep = try a.alloc(u8, 120);
    for (0..60) |i| @memcpy(deep[2 * i ..][0..2], "x/");
    const Case = struct { name: []const u8, piece: []const u8, times: usize, tail: []const u8, subject: []const u8 };
    const cases = [_]Case{
        .{ .name = "(*a)^32 b", .piece = "*a", .times = 32, .tail = "b", .subject = long_a },
        .{ .name = "*^64 b", .piece = "*", .times = 64, .tail = "b", .subject = long_a },
        .{ .name = "(**/)^32 z", .piece = "**/", .times = 32, .tail = "z", .subject = deep },
        .{ .name = "(*/**/)^30 z", .piece = "*/**/", .times = 30, .tail = "z", .subject = deep },
        .{ .name = "(**a)^20 b", .piece = "**a", .times = 20, .tail = "b", .subject = long_a },
        .{ .name = "{a,b}^20", .piece = "{a,b}", .times = 20, .tail = "", .subject = long_a[0..20] },
    };
    for (cases) |case| {
        var pattern: std.ArrayList(u8) = .empty;
        for (0..case.times) |_| try pattern.appendSlice(a, case.piece);
        try pattern.appendSlice(a, case.tail);
        const options: sweep.Options = .{ .syntax = .glob };
        // One call is a few microseconds: the best of many, so a cold cache
        // or a timer tick does not decide the row.
        var p: sweep.Pattern = try .compile(gpa, pattern.items, options);
        defer p.deinit();
        var one_shot_ns: f64 = std.math.inf(f64);
        var compiled_ns: f64 = std.math.inf(f64);
        for (0..if (smoke) 1 else 50) |_| {
            const t0 = r.now();
            const one_shot = try sweep.match(pattern.items, case.subject, options);
            const t1 = r.now();
            const compiled = p.matches(case.subject);
            const t2 = r.now();
            if (one_shot != compiled) return error.EnginesDisagree;
            one_shot_ns = @min(one_shot_ns, nsBetween(t0, t1));
            compiled_ns = @min(compiled_ns, nsBetween(t1, t2));
        }
        try r.line("adversarial", case.name, "one-shot", one_shot_ns / 1e3, "us");
        try r.line("adversarial", case.name, "compiled", compiled_ns / 1e3, "us");
    }
}

fn longPrefix(r: Report, gpa: Allocator, a: Allocator, smoke: bool) !void {
    const text = try a.alloc(u8, 9001);
    for (text[0..9000], 0..) |*byte, i| byte.* = if (i % 2 == 0) 'a' else 'b';
    text[9000] = '*';
    const subject = try a.dupe(u8, text);
    subject[9000] = 'c';
    var b: sweep.Set.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.add(text, .{});
    var set = try b.build();
    defer set.deinit();
    var best: f64 = std.math.inf(f64);
    var cold: f64 = std.math.inf(f64);
    for (0..if (smoke) 1 else 7) |_| {
        var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
        defer cache.deinit();
        const cold_start = r.now();
        if (!set.any(&cache, subject, .file)) return error.EnginesDisagree;
        cold = @min(cold, nsBetween(cold_start, r.now()));
        const start = r.now();
        const hit = set.any(&cache, subject, .file);
        const elapsed = nsBetween(start, r.now());
        if (!hit) return error.EnginesDisagree;
        best = @min(best, elapsed);
    }
    try r.line("long prefix", "9000 units", "set any cold", cold / 1e3, "us/query");
    try r.line("long prefix", "9000 units", "set any warm", best / 1e3, "us/query");
}

fn longRepeated(r: Report, gpa: Allocator, a: Allocator, smoke: bool) !void {
    const text = try a.alloc(u8, 9000);
    for (text, 0..) |*byte, i| byte.* = "ab*"[i % 3];
    const subject = try a.alloc(u8, 6000);
    for (subject, 0..) |*byte, i| byte.* = "ab"[i % 2];
    var b: sweep.Set.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.add(text, .{});
    var set = try b.build();
    defer set.deinit();
    var cold: f64 = std.math.inf(f64);
    var warm: f64 = std.math.inf(f64);
    for (0..if (smoke) @as(usize, 1) else 7) |_| {
        var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
        defer cache.deinit();
        var t = r.now();
        if (!set.any(&cache, subject, .file)) return error.EnginesDisagree;
        cold = @min(cold, nsBetween(t, r.now()));
        t = r.now();
        if (!set.any(&cache, subject, .file)) return error.EnginesDisagree;
        warm = @min(warm, nsBetween(t, r.now()));
    }
    try r.line("long repeats", "ab-star x3000", "set any cold", cold / 1e3, "us/query");
    try r.line("long repeats", "ab-star x3000", "set any warm", warm / 1e3, "us/query");
}

fn features(r: Report, gpa: Allocator, smoke: bool) !void {
    const cases = [_]struct { name: []const u8, text: []const u8, subject: []const u8, options: sweep.Options }{
        .{ .name = "integer interval", .text = "src/**/v{-1000000..1000000}.c", .subject = "src/lib/v-999999.c", .options = .{ .syntax = .editorconfig } },
        .{ .name = "regular extglob", .text = "src/+(lib|net)/test_?(io|tcp).zig", .subject = "src/libnet/test_tcp.zig", .options = .{ .syntax = .{ .extglob = true } } },
        .{ .name = "Unicode folding", .text = "src/[À-Ö]*Σ.c", .subject = "SRC/écoleς.C", .options = .{ .syntax = .glob, .case = .unicode } },
    };
    const rounds: usize = if (smoke) 1 else 10_000;
    for (cases) |case| {
        var compile_ns: f64 = std.math.inf(f64);
        var query_ns: f64 = std.math.inf(f64);
        var p = try sweep.Pattern.compile(gpa, case.text, case.options);
        defer p.deinit();
        for (0..7) |_| {
            var t = r.now();
            for (0..if (smoke) @as(usize, 1) else 100) |_| {
                var compiled = try sweep.Pattern.compile(gpa, case.text, case.options);
                compiled.deinit();
            }
            compile_ns = @min(compile_ns, nsBetween(t, r.now()) / (if (smoke) @as(f64, 1) else 100));
            t = r.now();
            for (0..rounds) |_| std.mem.doNotOptimizeAway(p.matches(case.subject));
            query_ns = @min(query_ns, nsBetween(t, r.now()) / @as(f64, @floatFromInt(rounds)));
        }
        try r.line("features", case.name, "compile", compile_ns / 1000, "us");
        try r.line("features", case.name, "matches", query_ns, "ns/query");
    }
    var p = try sweep.Pattern.compile(gpa, "src/*/?.{c,h}", .{ .syntax = .glob });
    defer p.deinit();
    const t = r.now();
    var cache = try p.captureCache(gpa);
    defer cache.deinit();
    try r.line("features", "capture scratch", "init", nsBetween(t, r.now()) / 1000, "us");
    var out: [4]?sweep.Pattern.Capture = undefined;
    var capture_ns: f64 = std.math.inf(f64);
    for (0..7) |_| {
        const start = r.now();
        for (0..rounds) |_| std.mem.doNotOptimizeAway(try p.captures(&cache, "src/lib/é.h", &out));
        capture_ns = @min(capture_ns, nsBetween(start, r.now()) / @as(f64, @floatFromInt(rounds)));
    }
    try r.line("features", "captures", "capture", capture_ns, "ns/query");
    try walking(r, gpa, smoke);
}

fn walking(r: Report, gpa: Allocator, smoke: bool) !void {
    const io = r.io;
    const root_path = ".zig-cache/sweep-bench-tree";
    try std.Io.Dir.cwd().createDirPath(io, root_path);
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    const root = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    const count: usize = if (smoke) 10 else 1000;
    for (0..count) |i| {
        const directory = try gpa.print("{s}/{d}", .{ if (i % 2 == 0) @as([]const u8, "src") else "other", i % 20 });
        defer gpa.free(directory);
        try root.createDirPath(io, directory);
        const name = try gpa.print("{s}/f{d}.c", .{ directory, i });
        defer gpa.free(name);
        try root.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var p = try sweep.Pattern.compile(gpa, "src/**/*.c", .{});
    defer p.deinit();
    var best: f64 = std.math.inf(f64);
    for (0..7) |_| {
        const t = r.now();
        var paths = try sweep.expand(gpa, io, root, .{ .pattern = &p }, .{ .files_only = true, .order = .lexical });
        defer paths.deinit();
        best = @min(best, nsBetween(t, r.now()));
        if (paths.items().len != count / 2) return error.MissingPaths;
    }
    try r.line("features", "walk 1000 files (half pruned)", "expand", best / 1e6, "ms");
}
