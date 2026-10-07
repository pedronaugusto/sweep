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
    try single(r, gpa, paths);
    try compile(r, gpa, if (smoke) 1 else 2_000);
    for (if (smoke) &[_]usize{100} else &[_]usize{ 100, 1_000, 10_000 }) |n| try sets(r, gpa, a, paths, n);
    try adversarial(r, gpa, a, smoke);
}

fn single(r: Report, gpa: Allocator, paths: []const []const u8) !void {
    for (gen.singles) |case| {
        const options: sweep.Options = .{ .anywhere = case[1] };
        var matched: usize = 0;
        const t0 = r.now();
        for (paths) |p| matched += @intFromBool(try sweep.match(case[0], p, options));
        const t1 = r.now();
        var pattern: sweep.Pattern = try .compile(gpa, case[0], options);
        defer pattern.deinit();
        var compiled: usize = 0;
        const t2 = r.now();
        for (paths) |p| compiled += @intFromBool(pattern.matches(p));
        const t3 = r.now();
        if (matched != compiled) return error.EnginesDisagree;
        const count: f64 = @floatFromInt(paths.len);
        try r.line("single", case[0], "one-shot", nsBetween(t0, t1) / count, "ns/path");
        try r.line("single", case[0], "compiled", nsBetween(t2, t3) / count, "ns/path");
        try r.line("single", case[0], "matched", @floatFromInt(matched), "paths");
    }
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
    var out: std.ArrayList(u32) = .empty;
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
