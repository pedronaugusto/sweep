//! The glob tests of the packages sweep replaces, kept as they move in.
//! Rows whose answer changed carry the reason.
const std = @import("std");
const sweep = @import("../glob.zig");

/// gantry's path rules: git's dialect with the basename rule.
fn pathRule(pattern: []const u8, subject: []const u8) bool {
    return sweep.match(pattern, subject, .{ .anywhere = true }) catch false;
}

/// gantry's token rules: every byte but `*` and `?` matches itself.
fn token(pattern: []const u8, text: []const u8) bool {
    return sweep.match(pattern, text, .{ .syntax = .{ .separator = null, .escape = false, .brackets = .none } }) catch false;
}

test "gantry: path globs are component-aware and double-star covers zero directories" {
    const cases = [_]struct { pattern: []const u8, path: []const u8, want: bool }{
        .{ .pattern = "src/**/*.zig", .path = "src/main.zig", .want = true },
        .{ .pattern = "src/**/*.zig", .path = "src/deep/main.zig", .want = true },
        .{ .pattern = "src/*.zig", .path = "src/deep/main.zig", .want = false },
        .{ .pattern = "**/main.zig", .path = "main.zig", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/b", .want = true },
        .{ .pattern = "**/a/**/b", .path = "x/a/z/a/c", .want = false },
        .{ .pattern = "a?c*", .path = "dir/abcde", .want = true },
        .{ .pattern = "src/*", .path = "src/deep/x", .want = false },
        // Flipped (owner decision 3): `a/**` needs the separator, as in git.
        .{ .pattern = "src/**", .path = "src", .want = false },
        .{ .pattern = "src/**", .path = "src/", .want = true },
        .{ .pattern = "src/**", .path = "src2/x", .want = false },
        .{ .pattern = "**", .path = "", .want = true },
        .{ .pattern = "*.zig", .path = "main.ZIG", .want = false },
        .{ .pattern = "a*b?d", .path = "a12b3d", .want = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, pathRule(case.pattern, case.path));
}

test "gantry: ** is a whole component and a slashless pattern the base name" {
    // Flipped (owner decision 3): `a/**` no longer matches `a`.
    try std.testing.expect(!pathRule("a/**", "a"));
    try std.testing.expect(pathRule("a/**", "a/b/c"));
    try std.testing.expect(pathRule("a/**/c", "a/c"));
    try std.testing.expect(!pathRule("a**/c", "ax/y/c"));
    try std.testing.expect(pathRule("a**/c", "ax/c"));
    try std.testing.expect(pathRule("*.zig", "src/x/a.zig"));
    try std.testing.expect(!pathRule("src/*.zig", "src/x/a.zig"));
}

test "gantry: token patterns, star spans any bytes and question mark one" {
    const cases = [_]struct { pattern: []const u8, text: []const u8, want: bool }{
        .{ .pattern = "kill", .text = "kill", .want = true },
        .{ .pattern = "kill", .text = "killpg", .want = false },
        .{ .pattern = "Create*W", .text = "CreateFileW", .want = true },
        .{ .pattern = "*.git*", .text = "a/.git/config", .want = true },
        .{ .pattern = "*.git", .text = ".gitignore", .want = false },
        .{ .pattern = "\x1b?", .text = "\x1b]", .want = true },
        // tycho's layer token: brackets stay literal in token rules.
        .{ .pattern = "*\x1b[*", .text = "say \x1b[0m", .want = true },
        .{ .pattern = "a\\b", .text = "a\\b", .want = true },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, token(case.pattern, case.text));
}

/// lookout's filter policy over sets: an ignore list wins, an include list
/// keeps what it names and the way down to it. Patterns are UTF-8 and use
/// the basename rule; one starting with `/` is matched against the
/// absolute path.
const Lookout = struct {
    ignore: sweep.Set,
    absolute: sweep.Set,
    only: sweep.Set,
    cache: [3]sweep.Set.Cache,

    const options: sweep.Options = .{ .syntax = .{ .unit = .utf8 }, .anywhere = true };

    fn init(ignore: []const []const u8, only: []const []const u8) !*Lookout {
        const gpa = std.testing.allocator;
        var b_ignore: sweep.Set.Builder = .init(gpa);
        defer b_ignore.deinit();
        var b_absolute: sweep.Set.Builder = .init(gpa);
        defer b_absolute.deinit();
        var b_only: sweep.Set.Builder = .init(gpa);
        defer b_only.deinit();
        for (ignore) |p| _ = try (if (p[0] == '/') &b_absolute else &b_ignore).add(p, .{ .options = options });
        for (only) |p| _ = try b_only.add(p, .{ .options = options });
        const l = try gpa.create(Lookout);
        l.* = .{ .ignore = try b_ignore.build(), .absolute = try b_absolute.build(), .only = try b_only.build(), .cache = undefined };
        l.cache[0] = try .init(gpa, &l.ignore, .{ .capacity = .fromRaw(1 << 16) });
        l.cache[1] = try .init(gpa, &l.absolute, .{ .capacity = .fromRaw(1 << 16) });
        l.cache[2] = try .init(gpa, &l.only, .{ .capacity = .fromRaw(1 << 16) });
        return l;
    }

    fn deinit(l: *Lookout) void {
        for (&l.cache) |*c| c.deinit();
        l.ignore.deinit();
        l.absolute.deinit();
        l.only.deinit();
        std.testing.allocator.destroy(l);
    }

    /// Whether `path` or a directory above it matches the set.
    fn underMatch(set: *const sweep.Set, cache: *sweep.Set.Cache, path: []const u8) bool {
        var it = set.ancestors(cache, path, .file);
        while (it.next()) |step| if (step.last != null) return true;
        return false;
    }

    fn ignored(l: *Lookout, root: []const u8, path: []const u8) bool {
        return underMatch(&l.ignore, &l.cache[0], relative(root, path)) or
            (!l.absolute.len().eql(.fromRaw(0)) and underMatch(&l.absolute, &l.cache[1], path));
    }

    fn relative(root: []const u8, path: []const u8) []const u8 {
        return if (path.len > root.len) path[root.len + 1 ..] else "";
    }

    fn excludes(l: *Lookout, root: []const u8, path: []const u8) bool {
        if (path.len == root.len) return false;
        if (l.ignored(root, path)) return true;
        if (l.only.len().eql(.fromRaw(0))) return false;
        return !underMatch(&l.only, &l.cache[2], relative(root, path));
    }

    fn prunes(l: *Lookout, root: []const u8, dir: []const u8) bool {
        if (l.ignored(root, dir)) return true;
        if (l.only.len().eql(.fromRaw(0))) return false;
        const rel = relative(root, dir);
        if (underMatch(&l.only, &l.cache[2], rel)) return false;
        return !l.only.leadsTo(&l.cache[2], rel);
    }
};

test "lookout: a name pattern excludes it at any depth, and everything below it" {
    const f = try Lookout.init(&.{"node_modules"}, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/node_modules"));
    try std.testing.expect(f.excludes("/w", "/w/node_modules/x/y.js"));
    try std.testing.expect(f.excludes("/w", "/w/a/node_modules/x"));
    try std.testing.expect(!f.excludes("/w", "/w/src/main.zig"));
    try std.testing.expect(!f.excludes("/w/node_modules", "/w/node_modules"));
}

test "lookout: a pattern holding a separator is the whole relative path" {
    const f = try Lookout.init(&.{"build/out"}, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/build/out"));
    try std.testing.expect(f.excludes("/w", "/w/build/out/app"));
    try std.testing.expect(!f.excludes("/w", "/w/build/src"));
    try std.testing.expect(!f.excludes("/w", "/w/a/build/out"));
}

test "lookout: a glob matches within one component and not across a separator" {
    const f = try Lookout.init(&.{ "*.tmp", "cache/*" }, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/a.tmp"));
    try std.testing.expect(f.excludes("/w", "/w/deep/a.tmp"));
    try std.testing.expect(!f.excludes("/w", "/w/a.txt"));
    try std.testing.expect(f.excludes("/w", "/w/cache/one"));
    try std.testing.expect(f.excludes("/w", "/w/cache/one/two"));
    try std.testing.expect(!f.excludes("/w", "/w/deep/cache/one"));
}

test "lookout: two stars cross a separator and stand for no directory at all" {
    const f = try Lookout.init(&.{"build/**"}, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/build/a.o"));
    try std.testing.expect(f.excludes("/w", "/w/build/deep/deeper/a.o"));
    try std.testing.expect(!f.excludes("/w", "/w/src/a.zig"));
    const g = try Lookout.init(&.{"src/**/*.tmp"}, &.{});
    defer g.deinit();
    try std.testing.expect(g.excludes("/w", "/w/src/a.tmp"));
    try std.testing.expect(g.excludes("/w", "/w/src/deep/deeper/a.tmp"));
    try std.testing.expect(!g.excludes("/w", "/w/src/a.zig"));
    try std.testing.expect(!g.excludes("/w", "/w/other/a.tmp"));
}

test "lookout: a question mark is exactly one character, one scalar" {
    const f = try Lookout.init(&.{"a?.txt"}, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/ab.txt"));
    try std.testing.expect(f.excludes("/w", "/w/a\xc3\xa9.txt"));
    try std.testing.expect(!f.excludes("/w", "/w/abc.txt"));
    try std.testing.expect(!f.excludes("/w", "/w/a.txt"));
}

test "lookout: an absolute pattern is matched against the absolute path" {
    const f = try Lookout.init(&.{"/w/a/b"}, &.{});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/a/b"));
    try std.testing.expect(f.excludes("/w", "/w/a/b/c"));
    try std.testing.expect(!f.excludes("/w", "/w/a/c"));
}

test "lookout: an include list keeps what it names and the way to it" {
    const f = try Lookout.init(&.{}, &.{"src/**/*.zig"});
    defer f.deinit();
    try std.testing.expect(!f.excludes("/w", "/w/src/main.zig"));
    try std.testing.expect(!f.excludes("/w", "/w/src/deep/main.zig"));
    try std.testing.expect(!f.prunes("/w", "/w/src"));
    try std.testing.expect(!f.prunes("/w", "/w/src/deep"));
    try std.testing.expect(f.prunes("/w", "/w/docs"));
    try std.testing.expect(f.excludes("/w", "/w/src/notes.txt"));
    try std.testing.expect(f.excludes("/w", "/w/docs"));
    try std.testing.expect(f.excludes("/w", "/w/docs/a.zig"));
}

test "lookout: two stars inside a name are one star, as in git" {
    // Flipped (approved breaking change): `a**/c` is `a*/c`, so it no
    // longer names `ax/y/c`, and the walk stops at `ax/y`.
    const f = try Lookout.init(&.{}, &.{"a**/c"});
    defer f.deinit();
    try std.testing.expect(f.excludes("/w", "/w/ax/y/c"));
    try std.testing.expect(!f.excludes("/w", "/w/ax/c"));
    try std.testing.expect(!f.prunes("/w", "/w/ax"));
    try std.testing.expect(f.prunes("/w", "/w/ax/y"));
    try std.testing.expect(f.prunes("/w", "/w/b"));
    const one = try Lookout.init(&.{}, &.{"a*c/d"});
    defer one.deinit();
    try std.testing.expect(!one.prunes("/w", "/w/abc"));
    try std.testing.expect(one.prunes("/w", "/w/ab"));
    try std.testing.expect(one.prunes("/w", "/w/abc/x"));
    const empty = try Lookout.init(&.{}, &.{"ab*/d"});
    defer empty.deinit();
    try std.testing.expect(!empty.prunes("/w", "/w/ab"));
    // Flipped too: `**a**` inside a name is `*a*`, so `b` cannot stand
    // for it.
    const found = try Lookout.init(&.{}, &.{"a*?a/**a**/"});
    defer found.deinit();
    try std.testing.expect(found.excludes("/w", "/w/aba/b/a.b"));
    try std.testing.expect(found.prunes("/w", "/w/aba/b"));
    try std.testing.expect(!found.prunes("/w", "/w/aba"));
}

test "lookout: an include list and an ignore list together, with the ignore winning" {
    const f = try Lookout.init(&.{"vendor"}, &.{"*.zig"});
    defer f.deinit();
    try std.testing.expect(!f.excludes("/w", "/w/main.zig"));
    try std.testing.expect(f.excludes("/w", "/w/main.txt"));
    try std.testing.expect(f.excludes("/w", "/w/vendor"));
    try std.testing.expect(f.excludes("/w", "/w/vendor/main.zig"));
    try std.testing.expect(!f.prunes("/w", "/w/deep"));
    try std.testing.expect(!f.excludes("/w", "/w/deep/main.zig"));
    try std.testing.expect(f.prunes("/w", "/w/vendor"));
}
