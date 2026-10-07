//! git's dialect, case by case, and against the reference.
const std = @import("std");
const sweep = @import("../sweep.zig");

const expect = std.testing.expect;

fn yes(pattern: []const u8, text: []const u8) !void {
    try expect(try sweep.match(pattern, text, .{}));
}

fn no(pattern: []const u8, text: []const u8) !void {
    try expect(!try sweep.match(pattern, text, .{}));
}

test "literals and stars" {
    try yes("foo.c", "foo.c");
    try no("foo.c", "foo.cc");
    try yes("", "");
    try no("", "x");
    try yes("*.c", "foo.c");
    try no("*.c", "sub/foo.c");
    try yes("a*b*c", "axxbyyc");
    try yes("*", "");
    try yes("**", "");
}

test "double star" {
    try yes("a/**/b", "a/b");
    try yes("a/**/b", "a/x/y/b");
    try no("a/**/b", "a/x/y/c");
    try yes("**/foo", "foo");
    try yes("**/foo", "a/b/c/foo");
    try no("**/foo", "a/foobar");
    try yes("a/**", "a/");
    try no("a/**", "a");
    try yes("a**/b", "axx/b");
    try no("a**/b", "a/x/b");
    try yes("a/**/x*y", "a/x/xzy");
    try no("a/**/x*y", "a/x/x/zy");
}
