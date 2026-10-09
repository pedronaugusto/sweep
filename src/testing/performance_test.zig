//! Deterministic guards for the strategies behind the measured workloads.
const std = @import("std");
const sweep = @import("../glob.zig");
const pattern_mod = @import("../pattern.zig");
const repeat = @import("shakedown").corpus.repeat;

test "compiled plain patterns do not determinize during compile" {
    for ([_][]const u8{ "*.[ch]", "**/README*", "src/**/test_*.zig" }) |text| {
        var p: sweep.Pattern = try .compile(std.testing.allocator, text, .{ .anywhere = true });
        defer p.deinit();
        try std.testing.expect(p.eager == null);
        for ([_][]const u8{ "src/a/test_b.zig", "main.c", "x.h", "a/README.md", "src/lib/a.rs", "" }) |subject| {
            try std.testing.expectEqual(pattern_mod.matchesBy(&p, subject, .nfa), p.matches(subject));
        }
    }
}

test "9000-unit literal prefix set queries build no DFA states" {
    const text = repeat("ab", 4500) ++ "*";
    const subject = repeat("ab", 4500) ++ "c";
    var b: sweep.Set.Builder = .init(std.testing.allocator);
    defer b.deinit();
    _ = try b.add(text, .{});
    var set = try b.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(std.testing.allocator, &set, .{ .capacity = .fromRaw(0) });
    defer cache.deinit();
    try std.testing.expect(set.any(&cache, subject, .file));
    try std.testing.expect(!set.any(&cache, subject ++ "/x", .file));
    try std.testing.expectEqual(@as(u64, 0), cache.stats().states);
}

test "9000-unit repeated ab-star Set queries build no DFA states" {
    var b: sweep.Set.Builder = .init(std.testing.allocator);
    defer b.deinit();
    _ = try b.add(repeat("ab*", 3000), .{});
    var set = try b.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(std.testing.allocator, &set, .{ .capacity = .fromRaw(0) });
    defer cache.deinit();
    try std.testing.expect(set.any(&cache, repeat("ab", 3000), .file));
    try std.testing.expect(!set.any(&cache, repeat("ab", 2999), .file));
    try std.testing.expectEqual(@as(u64, 0), cache.stats().states);
}
