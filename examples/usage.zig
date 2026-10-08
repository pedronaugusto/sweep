const std = @import("std");
const sweep = @import("sweep");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // --- README:usage ---
    // git's dialect: `*` stays in one component, `**/` spans any number.
    std.debug.assert(try sweep.match("src/**/*.zig", "src/a/b/c.zig", .{}));
    std.debug.assert(!try sweep.match("src/*.zig", "src/a/c.zig", .{}));
    // gitignore's rule for a pattern with no separator: any depth.
    std.debug.assert(try sweep.match("*.o", "build/x/y.o", .{ .anywhere = true }));
    // Braces and UTF-8 scalars in the glob dialect.
    std.debug.assert(try sweep.match("*.{c,h}", "main.h", .{ .syntax = .glob }));
    // --- README:usage ---
    try compiled(gpa);
    try ignore(gpa);
    try walking(gpa, init.io);
}

fn compiled(gpa: std.mem.Allocator) !void {
    // --- README:pattern ---
    var pattern: sweep.Pattern = try .compile(gpa, "src/**/test_*.zig", .{});
    defer pattern.deinit();
    std.debug.assert(pattern.matches("src/net/test_io.zig"));
    // Walking: start at the literal base, enter only what can lead to a match.
    std.debug.assert(std.mem.eql(u8, pattern.base(), "src"));
    std.debug.assert(pattern.leadsTo("src/net"));
    std.debug.assert(!pattern.leadsTo("docs"));
    // Capture scratch is separate and reusable, with one cache per thread.
    var captures = try pattern.captureCache(gpa);
    defer captures.deinit();
    var out: [4]?sweep.Pattern.Capture = undefined;
    std.debug.assert(try pattern.captures(&captures, "src/net/test_io.zig", &out));
    // Captures include the globstar directory and the filename's star.
    // --- README:pattern ---
}

fn ignore(gpa: std.mem.Allocator) !void {
    // --- README:set ---
    const lines = [_][]const u8{ "*.log", "!keep.log", "build/" };
    var builder: sweep.Set.Builder = .init(gpa);
    defer builder.deinit();
    var negated: [lines.len]bool = undefined;
    for (lines) |line| {
        const parsed = sweep.gitignore.parseLine(line) orelse continue;
        negated[try builder.add(parsed.pattern, parsed.entry)] = parsed.negated;
    }
    var set = try builder.build();
    defer set.deinit();
    // One cache per thread; queries allocate nothing.
    var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
    defer cache.deinit();
    // The last matching line decides, and a negated line re-includes.
    const ignored = struct {
        fn f(s: *const sweep.Set, c: *sweep.Set.Cache, n: []const bool, path: []const u8, kind: sweep.Kind) bool {
            return if (s.last(c, path, kind)) |i| !n[i] else false;
        }
    }.f;
    std.debug.assert(ignored(&set, &cache, &negated, "x/debug.log", .file));
    std.debug.assert(!ignored(&set, &cache, &negated, "x/keep.log", .file));
    std.debug.assert(ignored(&set, &cache, &negated, "build", .dir));
    // Every parent in one pass: a file under an ignored directory is ignored.
    var it = set.ancestors(&cache, "build/out/keep.log", .file);
    while (it.next()) |step| {
        if (step.last) |i| if (!negated[i]) break;
    }
    // --- README:set ---
}

fn walking(gpa: std.mem.Allocator, io: std.Io) !void {
    // --- README:walk ---
    var pattern = try sweep.Pattern.compile(gpa, "src/**/*.zig", .{});
    defer pattern.deinit();
    var walk = try sweep.Walk.open(gpa, io, .cwd(), .{ .pattern = &pattern }, .{
        .hidden = false,
        .files_only = true,
    });
    defer walk.deinit(io);
    while (try walk.next(io)) |entry| {
        // entry.path is borrowed until the next call or deinit.
        std.mem.doNotOptimizeAway(entry.path);
    }
    // --- README:walk ---
}
