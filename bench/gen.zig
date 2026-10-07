//! Seeded workloads: a synthetic source tree and pattern sets shaped like
//! real ignore files, the same on every run and every machine.
const std = @import("std");

const Allocator = std.mem.Allocator;

const dirs = [_][]const u8{
    "src",      "lib",    "include", "drivers", "net",   "fs",      "arch", "tools", "docs",  "test",
    "internal", "pkg",    "cmd",     "vendor",  "build", "scripts", "core", "util",  "third", "kernel",
    "mm",       "crypto", "sound",   "block",   "ipc",   "init",    "usr",  "virt",  "rust",  "security",
};
const stems = [_][]const u8{
    "main",   "util",  "config", "parser", "lexer", "server", "client", "io",       "buffer", "table",
    "hash",   "alloc", "thread", "queue",  "map",   "list",   "node",   "tree",     "graph",  "sched",
    "driver", "core",  "init",   "exit",   "file",  "inode",  "page",   "Makefile", "README", "test_io",
};
const extensions = [_][]const u8{ ".c", ".h", ".zig", ".rs", ".go", ".py", ".js", ".o", ".md", ".txt", ".json", ".S", "" };

/// `count` paths of a synthetic tree: depth 1 to 8, mostly 3 to 5, short
/// components, common extensions, a few hidden names.
pub fn tree(a: Allocator, count: usize, seed: u64) Allocator.Error![]const []const u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const out = try a.alloc([]const u8, count);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (out) |*path| {
        buf.clearRetainingCapacity();
        const depth = 1 + @min(7, r.uintLessThan(usize, 4) + r.uintLessThan(usize, 4));
        for (0..depth) |_| {
            try buf.appendSlice(a, dirs[r.uintLessThan(usize, dirs.len)]);
            if (r.uintLessThan(u8, 8) == 0) try buf.print(a, "{d}", .{r.uintLessThan(u8, 40)});
            try buf.append(a, '/');
        }
        if (r.uintLessThan(u8, 20) == 0) try buf.append(a, '.');
        try buf.appendSlice(a, stems[r.uintLessThan(usize, stems.len)]);
        if (r.uintLessThan(u8, 3) == 0) try buf.print(a, "_{d}", .{r.uintLessThan(u16, 500)});
        try buf.appendSlice(a, extensions[r.uintLessThan(usize, extensions.len)]);
        path.* = try a.dupe(u8, buf.items);
    }
    return out;
}

/// One entry of a synthetic set.
pub const Entry = struct { pattern: []const u8, dir_only: bool };

/// A set of `count` gitignore-shaped entries: 60% literals, base names and
/// extensions, 25% directory prefixes and path suffixes, 15% wildcards; one
/// in ten is directory-only.
pub fn set(a: Allocator, count: usize, seed: u64) Allocator.Error![]const Entry {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const out = try a.alloc(Entry, count);
    for (out) |*e| {
        const d = dirs[r.uintLessThan(usize, dirs.len)];
        const s = stems[r.uintLessThan(usize, stems.len)];
        const x = extensions[r.uintLessThan(usize, extensions.len - 1)];
        const n = r.uintLessThan(u16, 2000);
        const roll = r.uintLessThan(u8, 100);
        const pattern = if (roll < 20)
            try a.print("{s}/{s}{d}{s}", .{ d, s, n, x })
        else if (roll < 40)
            try a.print("{s}{d}{s}", .{ s, n, x })
        else if (roll < 60)
            try a.print("*{s}{d}", .{ x, n })
        else if (roll < 72)
            try a.print("{s}{d}/**", .{ d, n })
        else if (roll < 85)
            try a.print("**/{s}/{s}{d}", .{ d, s, n })
        else
            try a.print("{s}/**/{s}*{d}?{s}", .{ d, s[0..1], n, x });
        e.* = .{ .pattern = pattern, .dir_only = r.uintLessThan(u8, 10) == 0 };
    }
    return out;
}

/// Realistic single patterns, one per shape a caller writes.
pub const singles = [_]struct { []const u8, bool }{
    .{ "src/main.zig", false },
    .{ "*.c", true },
    .{ "**/*.rs", false },
    .{ "docs/**", false },
    .{ "drivers/*/Makefile", false },
    .{ "**/[Mm]akefile", false },
    .{ "src/**/test_*.zig", false },
    .{ "?*.o", true },
    .{ "*.[ch]", true },
    .{ "lib/**/util*.h", false },
    .{ "**/kernel/**/*.c", false },
    .{ "net/*/*.c", false },
    .{ "**/README*", false },
    .{ "*/*/*/*.json", false },
    .{ "[a-m]*/**/*.go", false },
};
