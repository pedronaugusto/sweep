//! sweep's input seam: the ignore files it reads from a tree, each held to
//! a size and opened through a link or not as the caller asks. Everything
//! else in sweep reads the bytes these hand it.
const builtin = @import("builtin");
const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;

pub const Links = enum {
    /// Read through a link: git follows `core.excludesFile` and
    /// `info/exclude`.
    follow,
    /// A link is `error.LinkRefused`: git's `PATTERN_NOFOLLOW` for a file in
    /// the working tree.
    refuse,
};

pub const ReadError = aegis.own.ReadFileError || aegis.own.ReadOpenedError || Io.Dir.OpenError || error{
    /// The file holds more than the `max` it is read with bytes; git skips one
    /// over its 100 MiB.
    FileTooLarge,
    /// The file's name is a symbolic link where `Links.refuse` was asked.
    LinkRefused,
};

/// `err`, from an open of `path` under `dir` that `follow`s links or not,
/// as `error.SymLinkLoop` where it is the open refusing a link. Linux and
/// macOS refuse `O_NOFOLLOW` on a link with ELOOP, which std names so;
/// FreeBSD refuses with EMLINK and NetBSD with EFTYPE, which std leaves
/// `error.Unexpected`: there the name is looked at, unfollowed, and only a
/// link turns the error. Every other error, and either errno anywhere
/// else, keeps its meaning.
pub fn noFollow(io: Io, dir: Io.Dir, path: []const u8, follow: bool, err: anytype) @TypeOf(err) {
    switch (builtin.os.tag) {
        .freebsd, .netbsd => {},
        else => return err,
    }
    if (follow or err != error.Unexpected) return err;
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return err;
    return if (stat.kind == .sym_link) error.SymLinkLoop else err;
}

/// The file at `path` under `dir`, at most `max` bytes, owned by the caller;
/// null where there is none.
pub fn file(io: Io, dir: Io.Dir, path: []const u8, gpa: std.mem.Allocator, max: aegis.units.Bytes(u64), links: Links) ReadError!?[]u8 {
    const bytes = switch (links) {
        .follow => aegis.own.readFile(io, dir, path, gpa, max),
        .refuse => opened: {
            // The open itself refuses a link (`O_NOFOLLOW`, git's
            // `open_nofollow`): nothing is looked at before it.
            const opened = dir.openFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return if (noFollow(io, dir, path, false, e) == error.SymLinkLoop) error.LinkRefused else e,
            };
            defer opened.close(io);
            break :opened aegis.own.readOpened(io, opened, gpa, max);
        },
    };
    return bytes catch |err| switch (err) {
        error.FileNotFound => null,
        error.StreamTooLong => error.FileTooLarge,
        else => |e| e,
    };
}
