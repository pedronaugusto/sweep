//! A compiled pattern against the one-shot matcher: every executor gives
//! the same answer, and `ancestor` and `leadsTo` equal brute force.
const std = @import("std");
const sweep = @import("../sweep.zig");
const gen = @import("gen.zig");
const pattern_mod = @import("../pattern.zig");

// The property loops build thousands of patterns; the testing allocator's
// bookkeeping would dominate them. Leaks and failures are allocation_test's.
const gpa = std.heap.smp_allocator;
const Pattern = sweep.Pattern;

fn compiled(pattern: []const u8, options: sweep.Options) !?Pattern {
    return Pattern.compile(gpa, pattern, options) catch |err| switch (err) {
        error.InvalidPattern => {
            try std.testing.expectError(error.InvalidPattern, sweep.match(pattern, "", options));
            return null;
        },
        else => return err,
    };
}

fn enginesOne(s: gen.Source) anyerror!void {
    var pattern_buf: [16]u8 = undefined;
    var text_buf: [16]u8 = undefined;
    const options = gen.options(s);
    const pattern = gen.string(s, &pattern_buf, &gen.any_pattern);
    var p = try compiled(pattern, options) orelse return;
    defer p.deinit();
    for (0..4) |_| {
        const text = gen.string(s, &text_buf, &gen.any_text);
        const want = try sweep.match(pattern, text, options);
        for ([_]pattern_mod.Executor{ .fastest, .strategy, .dfa, .nfa }) |executor| {
            if (pattern_mod.matchesBy(&p, text, executor) != want) {
                std.debug.print("engines: \"{f}\" vs \"{f}\" ({any}) {t}: want {}\n", .{ std.zig.fmtString(pattern), std.zig.fmtString(text), options, executor, want });
                return error.TestUnexpectedResult;
            }
        }
        // The shortest matching prefix that ends at a separator or the end.
        var expected: ?usize = null;
        if (options.syntax.separator) |sep| {
            var at: usize = 0;
            while (std.mem.findScalarPos(u8, text, at, sep)) |end| : (at = end + 1) {
                if (try sweep.match(pattern, text[0..end], options)) {
                    expected = end;
                    break;
                }
            }
        }
        if (expected == null and want) expected = text.len;
        // A separator inside a UTF-8 sequence is not one; the generator's
        // separators are ASCII, so byte positions agree.
        if (p.ancestor(text) != expected) {
            std.debug.print("ancestor: \"{f}\" vs \"{f}\" ({any}): want {?}, got {?}\n", .{ std.zig.fmtString(pattern), std.zig.fmtString(text), options, expected, p.ancestor(text) });
            return error.TestUnexpectedResult;
        }
    }
}

test "fuzz: every executor agrees with match, and ancestor with prefixes" {
    try std.testing.fuzz({}, gen.fuzzed(enginesOne), .{});
}

test "every executor agrees with match on seeded inputs" {
    try gen.seeded(enginesOne, 0xe9_9e5, 3000);
}

/// Units a brute-force `leadsTo` tries after the directory.
const rest_units = [_][]const u8{ "a", "b", "A", "z", "1", ".", "/", "\xc3\xa9", "\xff", ",", "{", "}", "]", "[", "!", "-", "\\", "*", "?", ":" };

/// Pieces whose shortest match is at most one unit, so a rest of three
/// units reaches every pattern of three pieces.
const short_pieces = [_][]const u8{
    "a", "b", "/", "*", "**", "?", "[", "]", "!", "-", ".", "A", "[:alpha:]", "[:upper:]", "[:digit:]", "[a-c]", "**/", "/**", "{a,b}", "{,", "}", ",", "\xc3\xa9", "\xff",
};

fn bruteLeads(pattern: []const u8, dir: []const u8, options: sweep.Options) !bool {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    @memcpy(buf[0..dir.len], dir);
    len = dir.len;
    if (dir.len > 0) if (options.syntax.separator) |sep| {
        buf[len] = sep;
        len += 1;
    };
    return search(pattern, &buf, len, 3, options);
}

fn search(pattern: []const u8, buf: []u8, len: usize, depth: usize, options: sweep.Options) !bool {
    if (try sweep.match(pattern, buf[0..len], options)) return true;
    if (depth == 0) return false;
    for (rest_units) |u| {
        @memcpy(buf[len..][0..u.len], u);
        if (try search(pattern, buf, len + u.len, depth - 1, options)) return true;
    }
    return false;
}

fn leadsOne(s: gen.Source) anyerror!void {
    var pattern_buf: [16]u8 = undefined;
    var dir_buf: [8]u8 = undefined;
    var options = gen.options(s);
    // Brackets and braces on, so each piece needs at most one unit.
    if (options.syntax.brackets == .none) options.syntax.brackets = .strict;
    options.syntax.braces = true;
    var len: usize = 0;
    for (0..s.index(4)) |_| {
        const piece = short_pieces[s.index(short_pieces.len)];
        if (len + piece.len > pattern_buf.len) break;
        @memcpy(pattern_buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    const pattern = pattern_buf[0..len];
    var p = try compiled(pattern, options) orelse return;
    defer p.deinit();
    const dir = gen.string(s, &dir_buf, &gen.git_text);
    const want = try bruteLeads(pattern, dir, options);
    if (p.leadsTo(dir) != want) {
        std.debug.print("leadsTo: \"{f}\" under \"{f}\" ({any}): want {}\n", .{ std.zig.fmtString(pattern), std.zig.fmtString(dir), options, want });
        return error.TestUnexpectedResult;
    }
}

test "leadsTo equals brute force on seeded inputs" {
    try gen.seeded(leadsOne, 0x1ead5, 150);
}

test "fuzz: leadsTo equals brute force" {
    try std.testing.fuzz({}, gen.fuzzed(leadsOne), .{});
}

test "base is the literal directory a walk starts from" {
    const cases = [_]struct { pattern: []const u8, options: sweep.Options = .{}, base: []const u8 }{
        .{ .pattern = "src/lib/**/*.zig", .base = "src/lib" },
        .{ .pattern = "src/lib/x.zig", .base = "src/lib" },
        .{ .pattern = "*.zig", .base = "" },
        .{ .pattern = "a\\*b/c/*", .base = "a*b/c" },
        .{ .pattern = "x.zig", .options = .{ .anywhere = true }, .base = "" },
        .{ .pattern = "{a,b}/c", .options = .{ .syntax = .glob }, .base = "" },
        .{ .pattern = "a/{b,c}/d", .options = .{ .syntax = .glob }, .base = "a" },
        .{ .pattern = "a/b", .options = .{ .syntax = .git_text }, .base = "" },
    };
    for (cases) |case| {
        var p: Pattern = try .compile(gpa, case.pattern, case.options);
        defer p.deinit();
        try std.testing.expectEqualStrings(case.base, p.base());
    }
}

test "literal patterns take a strategy, the rest a DFA" {
    const cases = [_]struct { pattern: []const u8, options: sweep.Options = .{}, strategy: bool }{
        .{ .pattern = "src/main.zig", .strategy = true },
        .{ .pattern = "*.zig", .options = .{ .anywhere = true }, .strategy = true },
        .{ .pattern = "**/*.zig", .strategy = true },
        .{ .pattern = "build/**", .strategy = true },
        .{ .pattern = "**/node_modules", .strategy = true },
        .{ .pattern = "**/a/b", .strategy = true },
        .{ .pattern = "src/foo*", .strategy = true },
        .{ .pattern = "src/**/test_*.zig", .strategy = false },
        .{ .pattern = "*.{c,h}", .options = .{ .syntax = .glob }, .strategy = false },
    };
    for (cases) |case| {
        var p: Pattern = try .compile(gpa, case.pattern, case.options);
        defer p.deinit();
        try std.testing.expectEqual(case.strategy, p.strategy != null);
        if (!case.strategy) try std.testing.expect(p.eager != null);
    }
    var p: Pattern = try .compile(gpa, "src/**/test_*.zig", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("src/", p.head);
    try std.testing.expectEqualStrings(".zig", p.tail);
}

test "patterns past the eager DFA's cap keep their NFA" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(gpa);
    for (0..40) |_| try pattern.appendSlice(gpa, "*a");
    try pattern.append(gpa, 'b');
    var p: Pattern = try .compile(gpa, pattern.items, .{});
    defer p.deinit();
    const text = gen.repeat("a", 300) ++ "b";
    try std.testing.expectEqual(try sweep.match(pattern.items, text, .{}), p.matches(text));
    try std.testing.expect(p.matches(text));
}

test "a pattern at the longest runs its NFA on the stack, and a longer one is a set's" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(gpa);
    for (0..Pattern.max_units / 2) |_| try pattern.appendSlice(gpa, "?*");
    var p: Pattern = try .compile(gpa, pattern.items, .{});
    defer p.deinit();
    const yes = gen.repeat("x", Pattern.max_units / 2);
    try std.testing.expect(pattern_mod.matchesBy(&p, yes, .nfa));
    try std.testing.expect(!pattern_mod.matchesBy(&p, yes[0 .. yes.len - 1], .nfa));
    // One unit more: refused, with the reason, and a set of one entry takes it.
    try pattern.append(gpa, 'x');
    var diagnostics: sweep.Diagnostics = .{ .reason = .unclosed_brace };
    try std.testing.expectError(error.PatternTooLong, Pattern.compile(gpa, pattern.items, .{ .diagnostics = &diagnostics }));
    try std.testing.expectEqual(sweep.Diagnostics.Reason.too_long, diagnostics.reason);
    var builder: sweep.Set.Builder = .init(gpa);
    defer builder.deinit();
    _ = try builder.add(pattern.items, .{});
    var set = try builder.build();
    defer set.deinit();
    var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
    defer cache.deinit();
    try std.testing.expect(set.any(&cache, yes ++ "x", .file));
    try std.testing.expect(!set.any(&cache, yes, .file));
}
