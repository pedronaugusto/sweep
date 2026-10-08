//! Path globs: git's wildmatch exactly, the common glob dialects, single
//! patterns and sets of them, in time linear in the subject.
const syntax = @import("syntax.zig");
const match_mod = @import("match.zig");
const helpers = @import("helpers.zig");
const pattern_mod = @import("pattern.zig");
const set_mod = @import("set.zig");

/// One glob dialect, field by field, with presets.
pub const Syntax = syntax.Syntax;
/// How letters compare.
pub const Case = syntax.Case;
/// What a pattern means: dialect, case and the basename rule.
pub const Options = syntax.Options;
/// Where and why a pattern was refused.
pub const Diagnostics = syntax.Diagnostics;
/// Why a pattern cannot be matched.
pub const PatternError = syntax.PatternError;

/// Whether a pattern matches all of a subject, with no allocation.
pub const match = match_mod.match;
/// The longest pattern, in units, `match` always takes.
pub const inline_units = match_mod.inline_units;

/// A pattern compiled once and matched many times.
pub const Pattern = pattern_mod.Pattern;
/// Why a pattern cannot be compiled.
pub const CompileError = pattern_mod.CompileError;

/// Many patterns matched in one pass.
pub const Set = set_mod.Set;
/// Whether a subject is a file or a directory.
pub const Kind = set_mod.Kind;

/// The line grammar of gitignore files.
pub const gitignore = @import("gitignore.zig");

/// Whether a byte has meaning outside brackets.
pub const isSpecial = helpers.isSpecial;
/// Length of a pattern's leading run with no special byte.
pub const literalPrefix = helpers.literalPrefix;
/// Writes a literal as a pattern that matches exactly it.
pub const escape = helpers.escape;
/// Errors from `escape`.
pub const EscapeError = helpers.EscapeError;

/// Filesystem glob expansion with pruning and explicit traversal policy.
pub const Walk = @import("walk.zig").Walk;
/// A borrowed Pattern or Set used by a filesystem walk.
pub const Matcher = @import("walk.zig").Matcher;
/// Owned glob expansion results.
pub const Paths = @import("walk.zig").Paths;
/// Expands a matcher against a directory.
pub const expand = @import("walk.zig").expand;
