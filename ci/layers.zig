//! Source layers, lowest first. Every production source has one place.
const gantry = @import("gantry");
const family = @import("preflight_rules");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "units and syntax", .patterns = &.{
        "src/fold.zig",
        "src/composition.zig",
        "src/unicode.zig",
        "src/unit.zig",
        "src/syntax.zig",
    } },
    .{ .name = "normalization", .patterns = &.{"src/normal.zig"} },
    .{ .name = "classes", .patterns = &.{
        "src/class.zig",
    } },
    .{ .name = "automaton", .patterns = &.{
        "src/program.zig",
    } },
    .{ .name = "parser, executor and literals", .patterns = &.{
        "src/integer.zig",
        "src/parse.zig",
        "src/nfa.zig",
        "src/strategy.zig",
        "src/direct.zig",
        "src/helpers.zig",
    } },
    .{ .name = "one-shot, DFA states and hashed literals", .patterns = &.{
        "src/match.zig",
        "src/capture.zig",
        "src/dfa.zig",
        "src/tables.zig",
        "src/scan.zig",
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
    .{ .name = "glob facade", .patterns = &.{"src/glob.zig"} },
    .{ .name = "walking", .patterns = &.{"src/walk.zig"} },
    .{ .name = "public", .patterns = &.{
        "src/sweep.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{};

const package_references = [_]gantry.rules.ReferenceRule{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "std",
        "aegis",
        "shakedown",
        "preflight_rules",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const references: []const gantry.rules.ReferenceRule = &(package_references ++ family.shakedown);
pub const owned: []const gantry.rules.TokenRule = &(family.durability ++ family.no_async);

pub const required = [_][]const u8{
    "src/fold.zig",
    "src/unicode.zig",
    "src/capture.zig",
    "src/walk.zig",
    "src/direct.zig",
    "src/unit.zig",
    "src/syntax.zig",
    "src/class.zig",
    "src/program.zig",
    "src/integer.zig",
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
    "src/glob.zig",
    "src/sweep.zig",
    "src/tests.zig",
};
