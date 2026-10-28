//! Ignore stacks against git 2.56.0: t0008-ignores.sh (`check-ignore -v`,
//! each answer's origin as git prints it) and t3001-ls-files-others-exclude.sh
//! (what `ls-files --others` lists), their trees built in a temporary
//! directory.
const std = @import("std");
const ignore = @import("../ignore.zig");
const walking = @import("../walk.zig");
const Kind = @import("../set.zig").Kind;
const gpa = std.testing.allocator;

fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// `want` is check-ignore -v's `source:line:pattern`, or null for `::`.
fn expectOrigin(c: *ignore.Checker, path: []const u8, kind: Kind, want: ?[]const u8, excluded: bool) !void {
    const m = try c.match(std.testing.io, path, kind);
    errdefer std.debug.print("path {s}\n", .{path});
    try std.testing.expectEqual(excluded, m.excluded);
    const w = want orelse return std.testing.expect(m.by == null);
    const by = m.by orelse return error.TestExpectedOrigin;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(w, try std.mem.print(&buf, "{s}:{d}:{s}", .{ by.source, by.line, by.text }));
}

/// t0008's setup: the tree, its three `.gitignore` levels, the global file
/// and `info/exclude`.
fn t0008(io: std.Io, dir: std.Io.Dir) !void {
    try write(io, dir, ".gitignore", "one\nignored-*\ntop-level-dir/\n");
    try write(io, dir, "a/.gitignore", "two*\n*three\n");
    try write(io, dir, "a/b/.gitignore",
        \\four
        \\five
        \\# this comment should affect the line numbers
        \\six
        \\ignored-dir/
        \\# and so should this blank line:
        \\
        \\!on*
        \\!two
        \\
    );
    try write(io, dir, "a/b/ignored-dir/.gitignore", "seven\n");
    try write(io, dir, "global-excludes", "globalone\n!globaltwo\nglobalthree\n");
    try write(io, dir, ".git/info/exclude", "per-repo\n");
}

fn t0008Checker(io: std.Io, dir: std.Io.Dir, global: bool) !ignore.Checker {
    var stack: ignore.Stack = .init(gpa, .{});
    errdefer stack.deinit();
    if (global) try stack.addFile(io, dir, "global-excludes", .{ .group = .file, .source = "global-excludes" }, .follow);
    try stack.addFile(io, dir, ".git/info/exclude", .{ .group = .file, .source = ".git/info/exclude" }, .follow);
    return .init(stack, dir);
}

test "t0008: standard ignores, at the top level and in a subdirectory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try t0008(io, tmp.dir);
    var c = try t0008Checker(io, tmp.dir, false);
    defer c.deinit();
    for ([_][]const u8{ "", "a/" }) |sub| {
        var buf: [64]u8 = undefined;
        try expectOrigin(&c, try std.mem.print(&buf, "{s}non-existent", .{sub}), .file, null, false);
        try expectOrigin(&c, try std.mem.print(&buf, "{s}one", .{sub}), .file, ".gitignore:1:one", true);
        try expectOrigin(&c, try std.mem.print(&buf, "{s}not-ignored", .{sub}), .file, null, false);
        try expectOrigin(&c, try std.mem.print(&buf, "{s}ignored-but-in-index", .{sub}), .file, ".gitignore:2:ignored-*", true);
        try expectOrigin(&c, try std.mem.print(&buf, "{s}ignored-and-untracked", .{sub}), .file, ".gitignore:2:ignored-*", true);
    }
    // Sub-directory local ignore, and the nested include of a negated pattern.
    try expectOrigin(&c, "a/3-three", .file, "a/.gitignore:2:*three", true);
    try expectOrigin(&c, "a/three-not-this-one", .file, null, false);
    try expectOrigin(&c, "a/b/one", .file, "a/b/.gitignore:8:!on*", false);
}

test "t0008: an ignored sub-directory decides everything inside it, its own files unread" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try t0008(io, tmp.dir);
    // git never reads a/b/ignored-dir/.gitignore: one it could not read
    // changes no answer.
    try tmp.dir.deleteFile(io, "a/b/ignored-dir/.gitignore");
    try tmp.dir.createDirPath(io, "a/b/ignored-dir/.gitignore");
    var c = try t0008Checker(io, tmp.dir, false);
    defer c.deinit();
    try expectOrigin(&c, "a/b/ignored-dir", .dir, "a/b/.gitignore:5:ignored-dir/", true);
    for ([_][]const u8{ "a/b/ignored-dir/foo", "a/b/ignored-dir/twoooo", "a/b/ignored-dir/seven" }) |path|
        try expectOrigin(&c, path, .file, "a/b/.gitignore:5:ignored-dir/", true);
    // cd a/b/ignored-dir; check-ignore -v foo twoooo ../one seven ../../one
    try expectOrigin(&c, "a/b/one", .file, "a/b/.gitignore:8:!on*", false);
    try expectOrigin(&c, "a/one", .file, ".gitignore:1:one", true);
}

test "t0008: global ignores, below info/exclude and every directory's file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try t0008(io, tmp.dir);
    {
        var c = try t0008Checker(io, tmp.dir, false);
        defer c.deinit();
        try expectOrigin(&c, "globalone", .file, null, false);
        try expectOrigin(&c, "per-repo", .file, ".git/info/exclude:1:per-repo", true);
        try expectOrigin(&c, "a/globalthree", .file, "a/.gitignore:2:*three", true);
        try expectOrigin(&c, "a/per-repo", .file, ".git/info/exclude:1:per-repo", true);
        try expectOrigin(&c, "a/globaltwo", .file, null, false);
    }
    var c = try t0008Checker(io, tmp.dir, true);
    defer c.deinit();
    try expectOrigin(&c, "globalone", .file, "global-excludes:1:globalone", true);
    try expectOrigin(&c, "per-repo", .file, ".git/info/exclude:1:per-repo", true);
    try expectOrigin(&c, "globalthree", .file, "global-excludes:3:globalthree", true);
    try expectOrigin(&c, "a/globalthree", .file, "a/.gitignore:2:*three", true);
    try expectOrigin(&c, "a/per-repo", .file, ".git/info/exclude:1:per-repo", true);
    try expectOrigin(&c, "not-ignored", .file, null, false);
    try expectOrigin(&c, "globaltwo", .file, "global-excludes:2:!globaltwo", false);
}

test "t0008: info/exclude trumps core.excludesFile" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addText("usually-ignored\n", .{ .group = .file, .source = "global-excludes" });
    try s.addText("!usually-ignored\n", .{ .group = .file, .source = ".git/info/exclude" });
    try std.testing.expect(!s.matchPath("usually-ignored", .file).excluded);
}

fn checkIgnored(s: *ignore.Stack, paths: []const struct { []const u8, Kind, bool }) !void {
    for (paths) |p| {
        errdefer std.debug.print("path {s}\n", .{p[0]});
        try std.testing.expectEqual(p[2], s.matchPath(p[0], p[1]).excluded);
    }
}

test "t0008: exact prefix matching, with and without a root" {
    for ([_][]const u8{ "/git/\n", "git/\n" }) |text| {
        var s: ignore.Stack = .init(gpa, .{});
        defer s.deinit();
        try s.addText(text, .{ .group = .directory, .base = "a", .source = "a/.gitignore" });
        try checkIgnored(&s, &.{
            .{ "a/git", .dir, true },
            .{ "a/git/foo", .file, true },
            .{ "a/git-foo", .dir, false },
            .{ "a/git-foo/bar", .file, false },
        });
    }
}

test "t0008: directories and ** matches" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addText("data/**\n!data/**/\n!data/**/*.txt\n", .{ .group = .directory, .source = ".gitignore" });
    try checkIgnored(&s, &.{
        .{ "file", .file, false },
        .{ "data/file", .file, true },
        .{ "data/data1/file1", .file, true },
        .{ "data/data1/file1.txt", .file, false },
        .{ "data/data2/file2", .file, true },
        .{ "data/data2/file2.txt", .file, false },
    });
}

test "t0008: ** not confused by a matching leading prefix" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addText("foo**/bar\n", .{ .group = .directory, .source = ".gitignore" });
    try checkIgnored(&s, &.{ .{ "foobar", .file, false }, .{ "foo/bar", .file, true } });
}

test "t0008: whitespace, quoting and backslashes" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addText("whitespace/trailing   \n", .{ .group = .file, .source = "ignore" });
    try checkIgnored(&s, &.{ .{ "whitespace/trailing", .file, true }, .{ "whitespace/untracked", .file, false } });
    var q: ignore.Stack = .init(gpa, .{});
    defer q.deinit();
    try q.addText("whitespace/trailing\\ \\ \n", .{ .group = .file, .source = "ignore" });
    try checkIgnored(&q, &.{ .{ "whitespace/trailing  ", .file, true }, .{ "whitespace/untracked", .file, false } });
    var b: ignore.Stack = .init(gpa, .{});
    defer b.deinit();
    try b.addText("whitespace/trailing 1 \\    \n" ++
        "whitespace/trailing 2 \\\\\\\\\n" ++
        "whitespace/trailing 3 \\\\\\\\ \n" ++
        "whitespace/trailing 4   \\\\\\    \n" ++
        "whitespace/trailing 5 \\\\ \\\\\\   \n" ++
        "whitespace/trailing 6 \\\\a\\\\\n", .{ .group = .file, .source = "ignore" });
    try checkIgnored(&b, &.{
        .{ "whitespace/trailing 1  ", .file, true },
        .{ "whitespace/trailing 2 \\\\", .file, true },
        .{ "whitespace/trailing 3 \\\\", .file, true },
        .{ "whitespace/trailing 4   \\ ", .file, true },
        .{ "whitespace/trailing 5 \\ \\ ", .file, true },
        .{ "whitespace/trailing 6 \\a\\", .file, true },
        .{ "whitespace/untracked", .file, false },
    });
}

test "t0008: links followed in the global files, refused in the tree" {
    // A symbolic link needs a privilege on Windows, and git there opens
    // without O_NOFOLLOW.
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, "ignore", "*\n");
    try tmp.dir.symLink(io, "ignore", "symlink", .{});
    {
        var s: ignore.Stack = .init(gpa, .{});
        defer s.deinit();
        try s.addFile(io, tmp.dir, "symlink", .{ .group = .file, .source = "symlink" }, .follow);
        try std.testing.expect(s.matchPath("file", .file).excluded);
    }
    try tmp.dir.symLink(io, "ignore", ".gitignore", .{});
    var refused: ignore.Stack = .init(gpa, .{});
    defer refused.deinit();
    try std.testing.expectError(error.LinkRefused, refused.addDirectory(io, tmp.dir, ""));
    // git warns and goes on: the file is absent, and said to be.
    var warned: ignore.Stack = .init(gpa, .{ .unreadable = .skip });
    defer warned.deinit();
    try warned.addDirectory(io, tmp.dir, "");
    try std.testing.expect(!warned.matchPath("file", .file).excluded);
    try std.testing.expectEqual(1, warned.skipped().len);
    try std.testing.expectEqualStrings(".gitignore", warned.skipped()[0].source);
    try std.testing.expectEqual(error.LinkRefused, warned.skipped()[0].reason);
}

test "t0008: a file past the limit is refused, or skipped and said to be" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, ".gitignore", "a-long-enough-line\n");
    var refused: ignore.Stack = .init(gpa, .{ .max_file = .fromRaw(8) });
    defer refused.deinit();
    try std.testing.expectError(error.FileTooLarge, refused.addDirectory(io, tmp.dir, ""));
    var warned: ignore.Stack = .init(gpa, .{ .max_file = .fromRaw(8), .unreadable = .skip });
    defer warned.deinit();
    try warned.addDirectory(io, tmp.dir, "");
    try std.testing.expectEqual(error.FileTooLarge, warned.skipped()[0].reason);
}

/// t3001's tree: four directories of `a.1` to `a.8`, three `#` files, and
/// the per-directory files.
fn t3001(io: std.Io, dir: std.Io.Dir, crlf: bool) !void {
    for ([_][]const u8{ ".", "one", "one/two", "three" }) |d| {
        for (1..9) |i| {
            var buf: [32]u8 = undefined;
            try write(io, dir, try std.mem.print(&buf, "{s}/a.{d}", .{ d, i }), "");
        }
    }
    for ([_][]const u8{ "#ignore1", "#ignore2", "#hidden" }) |name| try write(io, dir, name, "");
    try write(io, dir, ".gitignore", if (crlf) "*.1\r\n/*.3\r\n!*.6\r\n" else "*.1\n/*.3\n!*.6\n");
    try write(io, dir, "one/.gitignore", "*.2\ntwo/*.4\n!*.7\n*.8\n");
    try write(io, dir, "one/two/.gitignore", "!*.2\n!*.8\n");
}

/// `ls-files --others` with the stack: every file the walk returns.
fn others(io: std.Io, dir: std.Io.Dir, stack: *ignore.Stack, want: []const []const u8) !void {
    var paths = try walking.expand(gpa, io, dir, .everything, .{ .files_only = true, .order = .lexical, .ignore = stack });
    defer paths.deinit();
    errdefer for (paths.items()) |entry| std.debug.print("{s}\n", .{entry.path});
    try std.testing.expectEqual(want.len, paths.items().len);
    for (paths.items(), want) |entry, name| try std.testing.expectEqualStrings(name, entry.path);
}

test "t3001: --exclude, --exclude-per-directory and --exclude-from, with LF and CRLF lines" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |crlf| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try t3001(io, tmp.dir, crlf);
        var stack: ignore.Stack = .init(gpa, .{});
        defer stack.deinit();
        try stack.addText(".gitignore\n\\#ignore1\n\\#ignore2*\n\\#hid*n\noutput\nexpect\n.gitignore\n*.7\n!*.8\n", .{ .group = .file, .source = ".git/ignore" });
        try stack.addPatterns(&.{"*.6"}, .{ .group = .command_line, .source = "--exclude" });
        try others(io, tmp.dir, &stack, &.{
            "a.2",         "a.4",         "a.5",         "a.8",
            "one/a.3",     "one/a.4",     "one/a.5",     "one/a.7",
            "one/two/a.2", "one/two/a.3", "one/two/a.5", "one/two/a.7",
            "one/two/a.8", "three/a.2",   "three/a.3",   "three/a.4",
            "three/a.5",   "three/a.8",
        });
    }
}

test "t3001: trailing slashes, negations and excluded directories" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addPatterns(&.{ "one/", "two/", "one/a.1/" }, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&s, &.{
        .{ "one/a.1", .file, true },
        .{ "one/two/a.1", .file, true },
        .{ "two", .file, false },
        .{ "a.1", .file, false },
    });
    var n: ignore.Stack = .init(gpa, .{});
    defer n.deinit();
    try n.addPatterns(&.{ "a.*", "!a.1" }, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&n, &.{ .{ "a.1", .file, false }, .{ "a.2", .file, true } });
    var d: ignore.Stack = .init(gpa, .{});
    defer d.deinit();
    try d.addPatterns(&.{ "one", "!one/a.1" }, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&d, &.{.{ "one/a.1", .file, true }});
    var c: ignore.Stack = .init(gpa, .{});
    defer c.deinit();
    try c.addPatterns(&.{ "!one", "one/a.1" }, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&c, &.{ .{ "one/a.1", .file, true }, .{ "one/a.2", .file, false } });
}

test "t3001: subdirectory ignore" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, ".gitignore", "/.gitignore\nl1\n");
    try write(io, tmp.dir, "l1/.gitignore", "l2\n");
    try write(io, tmp.dir, "l1/l2/l1", "");
    var stack: ignore.Stack = .init(gpa, .{});
    defer stack.deinit();
    try others(io, tmp.dir, &stack, &.{});
}

test "t3001: ** patterns" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addPatterns(&.{"**/a.1"}, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&s, &.{ .{ "a.1", .file, true }, .{ "one/a.1", .file, true }, .{ "one/two/a.1", .file, true }, .{ "one/a.2", .file, false } });
    var p: ignore.Stack = .init(gpa, .{});
    defer p.deinit();
    try p.addPatterns(&.{ "one**a.1", "/three/a.3[abc]" }, .{ .group = .command_line, .source = "--exclude" });
    try checkIgnored(&p, &.{ .{ "one/a.1", .file, false }, .{ "three/a.3", .file, false } });
}

test "command-line patterns outrank every directory's, whenever they were added" {
    var s: ignore.Stack = .init(gpa, .{});
    defer s.deinit();
    try s.addPatterns(&.{"*.6"}, .{ .group = .command_line, .source = "--exclude" });
    try s.addText("!*.6\n", .{ .group = .directory, .source = ".gitignore" });
    try s.addText("!*.6\n", .{ .group = .directory, .base = "one", .source = "one/.gitignore" });
    try checkIgnored(&s, &.{ .{ "a.6", .file, true }, .{ "one/a.6", .file, true } });
}

test "a walk drops a directory's levels as it leaves it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, "x/.gitignore", "*.log\n");
    try write(io, tmp.dir, "x/a.log", "");
    try write(io, tmp.dir, "y/b.log", "");
    var stack: ignore.Stack = .init(gpa, .{});
    defer stack.deinit();
    const before = stack.mark();
    try others(io, tmp.dir, &stack, &.{ "x/.gitignore", "y/b.log" });
    try std.testing.expectEqual(before, stack.mark());
}

test "a walk starting below a pattern's base reads the ignore files above it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, ".gitignore", "*.o\n");
    try write(io, tmp.dir, "src/lib/.gitignore", "!keep.o\n");
    for ([_][]const u8{ "src/lib/a.o", "src/lib/keep.o", "src/lib/b.c" }) |path| try write(io, tmp.dir, path, "");
    try write(io, tmp.dir, "build/out.c", "");
    try write(io, tmp.dir, "build/.gitignore", "");
    const glob = @import("../glob.zig");
    var p: glob.Pattern = try .compile(gpa, "src/lib/*", .{});
    defer p.deinit();
    var stack: ignore.Stack = .init(gpa, .{});
    defer stack.deinit();
    var paths = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &p }, .{ .files_only = true, .order = .lexical, .ignore = &stack });
    defer paths.deinit();
    try std.testing.expectEqual(3, paths.items().len);
    try std.testing.expectEqualStrings("src/lib/.gitignore", paths.items()[0].path);
    try std.testing.expectEqualStrings("src/lib/b.c", paths.items()[1].path);
    try std.testing.expectEqualStrings("src/lib/keep.o", paths.items()[2].path);
    // A base its stack excludes yields nothing.
    var b: glob.Pattern = try .compile(gpa, "build/*", .{});
    defer b.deinit();
    try stack.addPatterns(&.{"build/"}, .{ .group = .command_line, .source = "--exclude" });
    var none = try walking.expand(gpa, io, tmp.dir, .{ .pattern = &b }, .{ .files_only = true, .ignore = &stack });
    defer none.deinit();
    try std.testing.expectEqual(0, none.items().len);
}

test "a checker reads each directory's files once, and again after one failed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(io, tmp.dir, "a/b/.gitignore", "*.log\n");
    try write(io, tmp.dir, "a/.gitignore", "!*.log\n");
    // A directory where a file is: unreadable until it is a file.
    try tmp.dir.createDirPath(io, "c/.gitignore");
    var c: ignore.Checker = .init(.init(gpa, .{}), tmp.dir);
    defer c.deinit();
    try std.testing.expect((try c.match(io, "a/b/x.log", .file)).excluded);
    try std.testing.expect(!(try c.match(io, "a/x.log", .file)).excluded);
    try std.testing.expectEqual(2, c.stack.levels.items.len);
    try std.testing.expect(std.meta.isError(c.match(io, "c/x.log", .file)));
    try tmp.dir.deleteDir(io, "c/.gitignore");
    try write(io, tmp.dir, "c/.gitignore", "*.log\n");
    try std.testing.expect((try c.match(io, "c/x.log", .file)).excluded);
}

const shake = @import("shakedown");
const gen = @import("gen.zig");
const dowild = @import("dowild.zig");
const gitignore = @import("../gitignore.zig");

/// One level of the model: what the stack was given.
const ModelLevel = struct { group: ignore.Group, base: []const u8, patterns: []const []const u8 };

/// git's `last_matching_pattern_from_list` for one level: its lines last
/// to first, a slash-free glob against the base name (`match_basename`),
/// any other against the path below the base (`match_pathname`).
fn modelLevel(level: ModelLevel, path: []const u8, kind: Kind, fold: bool) ?usize {
    const rel = if (level.base.len == 0) path else if (path.len > level.base.len and path[level.base.len] == '/' and std.mem.startsWith(u8, path, level.base)) path[level.base.len + 1 ..] else return null;
    var i = level.patterns.len;
    while (i > 0) {
        i -= 1;
        const line = gitignore.parsePattern(level.patterns[i]) orelse continue;
        if (line.entry.dir_only and kind != .dir) continue;
        const anywhere = line.entry.options.anywhere;
        const subject = if (anywhere) rel[if (std.mem.findScalarLast(u8, rel, '/')) |slash| slash + 1 else 0..] else rel;
        if (dowild.match(line.pattern, subject, .{ .pathname = !anywhere, .case_fold = fold }) catch false) return i;
    }
    return null;
}

const ModelHit = struct { level: usize, line: usize, negated: bool };

/// git's `last_matching_pattern_from_lists`: the groups highest first, the
/// levels of one group last added first.
fn modelDecide(levels: []const ModelLevel, path: []const u8, kind: Kind, fold: bool) ?ModelHit {
    for ([_]ignore.Group{ .command_line, .directory, .file }) |group| {
        var l = levels.len;
        while (l > 0) {
            l -= 1;
            if (levels[l].group != group) continue;
            const line = modelLevel(levels[l], path, kind, fold) orelse continue;
            return .{ .level = l, .line = line, .negated = gitignore.parsePattern(levels[l].patterns[line]).?.negated };
        }
    }
    return null;
}

/// git's walk: each directory above the path decided first, by the levels
/// above it; an excluded one decides.
fn modelPath(levels: []const ModelLevel, path: []const u8, kind: Kind, fold: bool) ?ModelHit {
    var at: usize = 0;
    while (std.mem.findScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
        if (modelDecide(levels, path[0..slash], .dir, fold)) |hit| if (!hit.negated) return hit;
    }
    return modelDecide(levels, path, kind, fold);
}

const bases = [_][]const u8{ "", "a", "a/b", "b" };
const components = [_][]const u8{ "a", "b", "ab", "A" };

fn stackAgainstGit(_: void, c: *shake.Case) anyerror!void {
    const s = c.source;
    const fold = gen.oneIn(s, 4);
    var pattern_bufs: [6][4][12]u8 = undefined;
    var pattern_lists: [6][4][]const u8 = undefined;
    var levels: [6]ModelLevel = undefined;
    const count = gen.index(s, levels.len + 1);
    var stack: ignore.Stack = .init(gpa, .{ .case = if (fold) .ascii_git else .sensitive });
    defer stack.deinit();
    var names: [6][2]u8 = undefined;
    for (levels[0..count], 0..) |*level, l| {
        const n = 1 + gen.index(s, 4);
        for (pattern_lists[l][0..n], pattern_bufs[l][0..n]) |*p, *buf| p.* = gen.string(s, buf, &gen.git_pattern);
        level.* = .{ .group = @fromBackingInt(@intCast(gen.index(s, 3))), .base = bases[gen.index(s, bases.len)], .patterns = pattern_lists[l][0..n] };
        names[l] = .{ 'L', '0' + @as(u8, @intCast(l)) };
        try stack.addPatterns(level.patterns, .{ .group = level.group, .base = level.base, .source = &names[l] });
    }
    var path_buf: [32]u8 = undefined;
    var len: usize = 0;
    for (0..1 + gen.index(s, 4)) |depth| {
        if (depth > 0) {
            path_buf[len] = '/';
            len += 1;
        }
        const part = components[gen.index(s, components.len)];
        @memcpy(path_buf[len..][0..part.len], part);
        len += part.len;
    }
    const path = path_buf[0..len];
    const kind: Kind = if (gen.oneIn(s, 2)) .dir else .file;
    const want = modelPath(levels[0..count], path, kind, fold);
    const got = stack.matchPath(path, kind);
    const agree = if (want) |hit| blk: {
        const by = got.by orelse break :blk false;
        break :blk got.excluded == !hit.negated and by.line == hit.line + 1 and by.source[1] == '0' + hit.level;
    } else got.by == null and !got.excluded;
    if (!agree) {
        std.debug.print("path {s} ({t}, fold {}): git {any}, stack {any}\n", .{ path, kind, fold, want, got });
        for (levels[0..count]) |level| std.debug.print("  {t} '{s}': {any}\n", .{ level.group, level.base, level.patterns });
        return error.TestUnexpectedResult;
    }
}

test "fuzz: a stack decides every path as git's own walk over its lists does" {
    try shake.check(gpa, {}, stackAgainstGit, .{ .cases = 2000 });
}

fn anyBytes(_: void, c: *shake.Case) anyerror!void {
    const s = c.source;
    var text_buf: [512]u8 = undefined;
    const text = text_buf[0..gen.index(s, text_buf.len + 1)];
    s.bytes(text);
    var path_buf: [64]u8 = undefined;
    const path = path_buf[0..gen.index(s, path_buf.len + 1)];
    s.bytes(path);
    var stack: ignore.Stack = .init(gpa, .{});
    defer stack.deinit();
    stack.addText(text, .{ .group = .directory, .source = "fuzz" }) catch |err| switch (err) {
        error.PatternTooLong => {},
        else => |e| return e,
    };
    stack.addPatterns(&.{text}, .{ .group = .command_line, .source = "fuzz" }) catch |err| switch (err) {
        error.PatternTooLong => {},
        else => |e| return e,
    };
    const whole = stack.matchPath(path, .file);
    const alone = stack.match(path, .file);
    // The path alone cannot be excluded where its parents are not and the
    // whole path is let through.
    if (alone.excluded and !whole.excluded and whole.by == null) return error.TestUnexpectedResult;
}

test "fuzz: any bytes as an ignore file and a path decide or are a named refusal" {
    try shake.check(gpa, {}, anyBytes, .{ .cases = 2000 });
}

test "every allocation a stack makes can fail, and leaves it as it was" {
    var no_resize = shake.alloc.NoResize.init(gpa);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn exercise(a: std.mem.Allocator) !void {
            var s: ignore.Stack = .init(a, .{ .case = .ascii_git });
            defer s.deinit();
            try s.addText("*.LOG\n!keep.log\n/blocked/\n!blocked/keep.log\n", .{ .group = .directory, .source = ".gitignore" });
            const kept = s.mark();
            try s.addPatterns(&.{ "!special.log", "x/" }, .{ .group = .command_line, .base = "sub", .source = "--exclude" });
            try std.testing.expect(s.matchPath("a.log", .file).excluded);
            try std.testing.expect(!s.matchPath("sub/special.log", .file).excluded);
            try std.testing.expect(s.matchPath("blocked/keep.log", .file).excluded);
            s.popTo(kept);
            try std.testing.expect(s.matchPath("sub/special.log", .file).excluded);
        }
    }.exercise, .{});
}
