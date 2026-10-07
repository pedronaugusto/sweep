//! Path globs: git's wildmatch exactly, the common glob dialects, single
//! patterns and sets of them, in time linear in the subject.
const syntax = @import("syntax.zig");
const match_mod = @import("match.zig");
const helpers = @import("helpers.zig");

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

/// Whether a byte has meaning outside brackets.
pub const isSpecial = helpers.isSpecial;
/// Length of a pattern's leading run with no special byte.
pub const literalPrefix = helpers.literalPrefix;
/// Writes a literal as a pattern that matches exactly it.
pub const escape = helpers.escape;
/// Errors from `escape`.
pub const EscapeError = helpers.EscapeError;
