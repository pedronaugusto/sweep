//! Construction and query boundaries exercised by the safety types.
const std = @import("std");
const sweep = @import("sweep");
const shakedown = @import("shakedown");
const Allocator = std.mem.Allocator;
const Error = Allocator.Error || sweep.PatternError || sweep.Set.AddError || sweep.Set.BuildError || sweep.Pattern.CaptureError;
const Mode = enum { one_shot, compile_pattern, compile_numeric, build_set, cache_init, set_last, set_all, ancestors, capture_init, captures };
const pattern_text = "src/**/{test_*,main,[a-z]*}.zig";
const subject = "src/lib/deep/test_core.zig";
const options: sweep.Options = .{ .syntax = .glob };

const Context = struct {
    gpa: Allocator,
    pattern: sweep.Pattern,
    capture: sweep.Pattern.CaptureCache,
    set: sweep.Set,
    cache: sweep.Set.Cache,
    out: std.ArrayList(sweep.Set.Index) = .empty,
    mode: Mode = .one_shot,

    fn run(c: *Context, n: u64) Error!void {
        var hits: usize = 0;
        for (0..n) |_| switch (c.mode) {
            .one_shot => hits += @intFromBool(try sweep.match(pattern_text, subject, options)),
            .compile_pattern, .compile_numeric => {
                const numeric = c.mode == .compile_numeric;
                var p = try sweep.Pattern.compile(c.gpa, if (numeric) "{-123456..654321}" else pattern_text, if (numeric) .{ .syntax = .editorconfig } else options);
                hits += @intFromBool(p.matches(if (numeric) "123456" else subject));
                p.deinit();
            },
            .build_set => {
                var builder: sweep.Set.Builder = .init(c.gpa);
                defer builder.deinit();
                for (entries) |text| _ = try builder.add(text, .{ .options = options });
                var set = try builder.build();
                hits += set.len().raw();
                set.deinit();
            },
            .cache_init => {
                var cache = try sweep.Set.Cache.init(c.gpa, &c.set, .{});
                std.mem.doNotOptimizeAway(&cache);
                cache.deinit();
            },
            .set_last => hits += @intFromBool(c.set.last(&c.cache, subject, .file) != null),
            .set_all => {
                c.out.clearRetainingCapacity();
                try c.set.all(c.gpa, &c.cache, subject, .file, &c.out);
                hits += c.out.items.len;
            },
            .ancestors => {
                var it = c.set.ancestors(&c.cache, subject, .file);
                while (it.next()) |step| hits += @intFromBool(step.last != null);
            },
            .capture_init => {
                var cache = try c.pattern.captureCache(c.gpa);
                hits += cache.count();
                cache.deinit();
            },
            .captures => {
                var result: [8]?sweep.Pattern.Capture = undefined;
                hits += @intFromBool(try c.pattern.captures(&c.capture, subject, &result));
                std.mem.doNotOptimizeAway(&result);
            },
        };
        std.mem.doNotOptimizeAway(hits);
    }
};

const entries = [_][]const u8{
    "src/**",        "**/*.zig",             "src/lib/*/*.zig",          "**/test_*.zig", "src/**/{main,test_*}.zig",
    "**/[a-z]*.zig", "src/**/test_core.zig", "src/{lib,other}/**/*.zig",
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var c: Context = .{ .gpa = gpa, .pattern = try .compile(gpa, pattern_text, options), .capture = undefined, .set = undefined, .cache = undefined };
    defer c.pattern.deinit();
    c.capture = try c.pattern.captureCache(gpa);
    defer c.capture.deinit();
    var builder: sweep.Set.Builder = .init(gpa);
    defer builder.deinit();
    for (entries) |text| _ = try builder.add(text, .{ .options = options });
    c.set = try builder.build();
    defer c.set.deinit();
    c.cache = try .init(gpa, &c.set, .{});
    defer c.cache.deinit();
    defer c.out.deinit(gpa);
    var policy: shakedown.bench.Options = .{ .samples = 1, .minimum = .fromMilliseconds(15) };
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            policy.smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--row=")) {
            policy.prefix = arg[6..];
            policy.minimum = .fromMilliseconds(60);
        } else return error.UnknownArgument;
    }
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    for (std.enums.values(Mode)) |mode| {
        c.mode = mode;
        try shakedown.bench.run(Error, gpa, init.io, &out.interface, &c, &.{.{ .name = @tagName(mode), .unit = "operation", .run = Context.run }}, .{ .commit = "construction-query-boundaries" }, policy);
    }
    try out.interface.flush();
}
