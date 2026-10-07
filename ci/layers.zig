//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "units and syntax", .patterns = &.{
        "src/unit.zig",
        "src/syntax.zig",
    } },
    .{ .name = "classes", .patterns = &.{
        "src/class.zig",
    } },
    .{ .name = "automaton", .patterns = &.{
        "src/program.zig",
    } },
    .{ .name = "parser and executor", .patterns = &.{
        "src/parse.zig",
        "src/nfa.zig",
    } },
    .{ .name = "matching and helpers", .patterns = &.{
        "src/match.zig",
        "src/helpers.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/sweep.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/unit.zig",
    "src/syntax.zig",
    "src/class.zig",
    "src/program.zig",
    "src/parse.zig",
    "src/nfa.zig",
    "src/match.zig",
    "src/helpers.zig",
    "src/sweep.zig",
    "src/tests.zig",
};
