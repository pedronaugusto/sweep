const std = @import("std");
const sweep = @import("../sweep.zig");
const pattern_mod = @import("../pattern.zig");

fn agrees(pattern: []const u8, subject: []const u8, options: sweep.Options, want: bool) !void {
    try std.testing.expectEqual(want, try sweep.match(pattern, subject, options));
    var p: sweep.Pattern = try .compile(std.testing.allocator, pattern, options);
    defer p.deinit();
    try std.testing.expectEqual(want, p.matches(subject));
    try std.testing.expectEqual(want, pattern_mod.matchesBy(&p, subject, .nfa));
    var builder: sweep.Set.Builder = .init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.add(pattern, .{ .options = options });
    var set = try builder.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(std.testing.allocator, &set, .{ .capacity = 0 });
    defer cache.deinit();
    try std.testing.expectEqual(want, set.any(&cache, subject, .file));
}

test "complete regular extglob optional, repeat, alternate and nesting" {
    const o: sweep.Options = .{ .syntax = .{ .extglob = true, .braces = true } };
    try agrees("a?(b|c)d", "ad", o, true);
    try agrees("a?(b|c)d", "abd", o, true);
    try agrees("a?(b|c)d", "abcd", o, false);
    try agrees("a+(b|cd)e", "abcdbe", o, true);
    try agrees("a+(b|cd)e", "ae", o, false);
    try agrees("*(a|?(b))c", "abababc", o, true);
    try agrees("*(a|?(b))c", "c", o, true);
    try agrees("@({a,b}|+(c|d))", "cddc", o, true);
    try agrees("@(a|b)", "ab", o, false);
    try agrees("*(|a)", "aaa", o, true);
    try std.testing.expectError(error.InvalidPattern, sweep.match("+(a", "a", o));
    try std.testing.expectError(error.InvalidPattern, sweep.match("!(a)", "a", o));
}

test "complete compiled direct eligibility respects custom separators" {
    const options: sweep.Options = .{ .syntax = .{ .separator = ':' } };
    try agrees("a*:*", "ax:dir:child", options, false);
    try agrees("a*:*", "ax:dir", options, true);
}

test "complete single-entry Set direct reading keeps disabled brackets literal" {
    const options: sweep.Options = .{ .syntax = .{ .brackets = .none } };
    try agrees("a*[xy]", "aabc[xy]", options, true);
    try agrees("a*[xy]", "aabcx", options, false);
    try agrees("A*[XY]", "aabc[xy]", .{ .syntax = .{ .brackets = .none }, .case = .ascii }, true);
}

test "complete editorconfig decimal intervals do not expand" {
    const o: sweep.Options = .{ .syntax = .editorconfig };
    for ([_][]const u8{ "3", "9", "10", "99", "120", "+60" }) |subject| try agrees("{3..120}", subject, o, true);
    for ([_][]const u8{ "2", "121", "060", "-3" }) |subject| try agrees("{3..120}", subject, o, false);
    try agrees("x{1..3}", "x2", .{ .syntax = .{ .numeric_ranges = true } }, true);
    try agrees("v{-12..12}.c", "v-10.c", o, true);
    try agrees("v{-12..12}.c", "v0.c", o, true);
    try agrees("v{-12..12}.c", "v13.c", o, false);
    try agrees("x{1..9223372036854775807}", "x9223372036854775807", o, true);
    var wide = try sweep.Pattern.compile(std.testing.allocator, "{-9223372036854775808..9223372036854775807}", o);
    defer wide.deinit();
    for ([_][]const u8{ "-9223372036854775808", "9223372036854775807", "0", "-0", "+0" }) |subject| try std.testing.expect(wide.matches(subject));
    try std.testing.expect(!wide.matches("9223372036854775808"));
    try agrees("ab[e/]cd.i", "x/ab[e/]cd.i", o, true);
    try agrees("ab[e/]cd.i", "abecd.i", o, false);
    try agrees("ab[/c", "ab[/c", o, true);
    try agrees("{s1}", "{s1}", o, true);
    try agrees("{s1}", "s1", o, false);
    try agrees("{.f", "{.f", o, true);
    try agrees("{},b}.h", "{},b}.h", o, true);
    try agrees("*.c", "x/y/z.c", o, true);
    try agrees("/src/**.c", "src/x/y.c", o, true);
    try agrees("src/**/a", "src/a", o, true);
    try agrees("src/**/a", "src/x/y/a", o, true);
    var rooted = try sweep.Pattern.compile(std.testing.allocator, "/src/*.c", o);
    defer rooted.deinit();
    try std.testing.expectEqualStrings("src", rooted.base());
    try std.testing.expectError(error.InvalidPattern, sweep.match("{3..1}", "2", o));
}

test "complete Unicode simple folding covers scalar and range equivalence" {
    const o: sweep.Options = .{ .syntax = .glob, .case = .unicode };
    try agrees("Σ?", "ςa", o, true);
    try agrees("[Σ]", "ς", o, true);
    try agrees("[À-Ö]", "é", o, true);
    try agrees("[!Σ]", "σ", o, false);
    try agrees("K", "K", o, true);
    try agrees("µ", "Μ", o, true);
    try agrees("İ", "i", o, false);
    try agrees("ß", "SS", o, false);
    try agrees("ẞ", "ß", o, true);
    try agrees("\\Σ", "σ", o, true);
    try agrees("\xff", "\xff", o, true);
    try agrees("?", "\xff", o, true);
    const custom: sweep.Options = .{ .syntax = .{ .separator = 'k' }, .case = .unicode };
    try agrees("[K]", "K", custom, true);
    try agrees("[K]", "K", custom, true);
    try agrees("[K]", "k", custom, false);
    try agrees("K?", "Kx", custom, true);
    try agrees("V{0..10}[Σ]", "v+10ς", .{ .syntax = .editorconfig, .case = .unicode }, true);
}

test "complete captures are greedy byte ranges and optional on ordinary matching" {
    var p: sweep.Pattern = try .compile(std.testing.allocator, "src/*/?.{c,h}", .{ .syntax = .glob });
    defer p.deinit();
    var cache = try p.captureCache(std.testing.allocator);
    defer cache.deinit();
    var out: [8]?sweep.Pattern.Capture = undefined;
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    try std.testing.expect(try p.captures(&cache, "src/lib/é.h", &out));
    try std.testing.expectEqualDeep(@as(?sweep.Pattern.Capture, .{ .start = 4, .end = 7 }), out[0]);
    try std.testing.expectEqualDeep(@as(?sweep.Pattern.Capture, .{ .start = 8, .end = 10 }), out[1]);
    try std.testing.expectEqualDeep(@as(?sweep.Pattern.Capture, .{ .start = 11, .end = 12 }), out[2]);
    try std.testing.expect(!try p.captures(&cache, "src/lib/a.rs", &out));
    try std.testing.expectError(error.BufferTooSmall, p.captures(&cache, "", out[0..1]));
    var greedy: sweep.Pattern = try .compile(std.testing.allocator, "*a*", .{});
    defer greedy.deinit();
    var scratch = try greedy.captureCache(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try greedy.captures(&scratch, "aaba", &out));
    try std.testing.expectEqualDeep(@as(?sweep.Pattern.Capture, .{ .start = 0, .end = 3 }), out[0]);
    try std.testing.expectEqualDeep(@as(?sweep.Pattern.Capture, .{ .start = 4, .end = 4 }), out[1]);
}
