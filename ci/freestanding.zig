//! The pure matching and capture APIs build for wasm32-freestanding in
//! `zig build check-freestanding`, and its exports reach every public
//! query, while filesystem expansion stays in its optional Io layer.
const std = @import("std");
const sweep = @import("sweep");

var heap: [1 << 20]u8 = undefined;

export fn sweepMatch(pattern: [*]const u8, pattern_len: usize, subject: [*]const u8, subject_len: usize) i32 {
    const matched = sweep.match(pattern[0..pattern_len], subject[0..subject_len], .{ .syntax = .glob }) catch return -1;
    return @intFromBool(matched);
}

/// Compiles a pattern and asks it every question: bit 0 `matches`, bit 1
/// `ancestor`, bit 2 `leadsTo`, bit 3 `base`; -1 when it cannot be compiled.
export fn sweepPattern(pattern: [*]const u8, pattern_len: usize, subject: [*]const u8, subject_len: usize) i32 {
    var fixed: std.heap.FixedBufferAllocator = .init(&heap);
    var p = sweep.Pattern.compile(fixed.allocator(), pattern[0..pattern_len], .{}) catch return -1;
    defer p.deinit();
    const text = subject[0..subject_len];
    var bits: i32 = @intFromBool(p.matches(text));
    if (p.ancestor(text) != null) bits |= 2;
    if (p.leadsTo(text)) bits |= 4;
    if (p.base().len > 0) bits |= 8;
    return bits;
}

/// Builds a set of one ignore line and asks it every question: bit 0
/// `any`, bit 1 `first`, bit 2 `last`, bit 3 `all`, bit 4 `ancestors`,
/// bit 5 `leadsTo`, bit 6 a clear; -1 when it cannot be built.
export fn sweepSet(line: [*]const u8, line_len: usize, subject: [*]const u8, subject_len: usize) i32 {
    var fixed: std.heap.FixedBufferAllocator = .init(&heap);
    const gpa = fixed.allocator();
    const parsed = sweep.gitignore.parseLine(line[0..line_len]) orelse return -1;
    var builder: sweep.Set.Builder = .init(gpa);
    defer builder.deinit();
    _ = builder.add(parsed.pattern, parsed.entry) catch return -1;
    var set = builder.build() catch return -1;
    defer set.deinit();
    var cache: sweep.Set.Cache = sweep.Set.Cache.init(gpa, &set, .{ .capacity = .fromRaw(1 << 16) }) catch return -1;
    defer cache.deinit();
    const text = subject[0..subject_len];
    var bits: i32 = @intFromBool(set.any(&cache, text, .file));
    if (set.first(&cache, text, .dir) != null) bits |= 2;
    if (set.last(&cache, text, .file) != null) bits |= 4;
    var out: std.ArrayList(sweep.Set.Index) = .empty;
    defer out.deinit(gpa);
    set.all(gpa, &cache, text, .file, &out) catch return -1;
    if (out.items.len > 0) bits |= 8;
    var it = set.ancestors(&cache, text, .file);
    while (it.next()) |step| if (step.last != null) {
        bits |= 16;
    };
    if (set.leadsTo(&cache, text)) bits |= 32;
    if (cache.stats().clears > 0) bits |= 64;
    return bits;
}

/// Writes `text` into `out` as a pattern that matches exactly it; returns
/// its length, or -1.
export fn sweepEscape(text: [*]const u8, text_len: usize, out: [*]u8, out_len: usize) isize {
    var w: std.Io.Writer = .fixed(out[0..out_len]);
    sweep.escape(&w, text[0..text_len], .git) catch return -1;
    return @intCast(w.buffered().len);
}

/// The length of a pattern's leading run with no special byte.
export fn sweepLiteralPrefix(pattern: [*]const u8, pattern_len: usize) usize {
    return sweep.literalPrefix(pattern[0..pattern_len], .git);
}

/// Whether a byte has meaning outside brackets in git's dialect.
export fn sweepIsSpecial(byte: u8) bool {
    return sweep.isSpecial(byte, .git);
}

/// Unicode folding, regular groups and captures also require no OS.
export fn sweepCaptures(subject: [*]const u8, subject_len: usize) i32 {
    var fixed: std.heap.FixedBufferAllocator = .init(&heap);
    var p = sweep.Pattern.compile(fixed.allocator(), "+(Σ|K)*", .{ .syntax = .{ .extglob = true }, .case = .unicode }) catch return -1;
    defer p.deinit();
    var cache = p.captureCache(fixed.allocator()) catch return -1;
    defer cache.deinit();
    var out: [4]?sweep.Pattern.Capture = undefined;
    return @intFromBool(p.captures(&cache, subject[0..subject_len], &out) catch return -1);
}
