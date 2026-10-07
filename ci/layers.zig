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
    .{ .name = "parser, executor and literals", .patterns = &.{
        "src/parse.zig",
        "src/nfa.zig",
        "src/strategy.zig",
        "src/direct.zig",
        "src/helpers.zig",
    } },
    .{ .name = "one-shot, DFA states and hashed literals", .patterns = &.{
        "src/match.zig",
        "src/dfa.zig",
        "src/tables.zig",
    } },
    .{ .name = "compiled patterns and lazy DFAs", .patterns = &.{
        "src/pattern.zig",
        "src/lazy.zig",
    } },
    .{ .name = "sets", .patterns = &.{
        "src/set.zig",
    } },
    .{ .name = "line grammar", .patterns = &.{
        "src/gitignore.zig",
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
    "src/strategy.zig",
    "src/helpers.zig",
    "src/match.zig",
    "src/dfa.zig",
    "src/tables.zig",
    "src/pattern.zig",
    "src/lazy.zig",
    "src/set.zig",
    "src/gitignore.zig",
    "src/sweep.zig",
    "src/tests.zig",
};
