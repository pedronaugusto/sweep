//! What a pattern means: the dialect, case rules and per-call options.

/// One glob dialect, field by field. The presets name common combinations;
/// every field is independent of the others.
pub const Syntax = struct {
    /// `*`, `?` and brackets never match this byte, and a `**` bounded by it
    /// is a globstar. Null is text mode: `*` and `**` match any run, `?` and
    /// brackets match anything.
    separator: ?u8 = '/',
    /// A second spelling of the separator, for native Windows path globs.
    alternate_separator: ?u8 = null,
    /// What a run of two or more `*` means.
    globstar: Globstar = .component,
    /// `\x` matches `x` literally, inside and outside brackets. Off makes `\`
    /// an ordinary unit.
    escape: bool = true,
    /// What `[` opens.
    brackets: Brackets = .strict,
    /// Brackets containing an unescaped separator are literal text.
    bracket_separator_literal: bool = false,
    /// `{a,b,c}` alternation, nestable, with empty alternatives allowed.
    braces: bool = false,
    /// A separator-bounded `/**/` also matches zero directories when every
    /// globstar crosses separators.
    globstar_slash: bool = false,
    /// What one `?` or one bracket consumes.
    unit: Unit = .byte,
    /// Decimal integer intervals `{n..m}`, compiled without expansion.
    numeric_ranges: bool = false,
    /// Regular extglobs `?()`, `*()`, `+()` and `@()`.
    extglob: bool = false,
    /// Separator-free patterns match the last component at any depth.
    basename: bool = false,
    /// A leading separator anchors relative to the supplied root.
    root_slash: bool = false,
    /// Brace groups without a comma keep their braces literally.
    single_brace_literal: bool = false,
    /// Whether a `.` that begins a component is hidden from wildcards.
    leading_dot: LeadingDot = .ordinary,

    /// What a run of two or more `*` means.
    pub const Globstar = enum {
        /// `**` is `*`.
        off,
        /// `**` standing as a whole component matches zero or more
        /// components; anywhere else it is `*` (git's `WM_PATHNAME`).
        component,
        /// Every `**` matches any run, separators included.
        anywhere,
    };

    /// What `[` opens.
    pub const Brackets = enum {
        /// `[` is an ordinary unit.
        none,
        /// An unclosed `[` or an unknown `[:class:]` is `error.InvalidPattern`.
        strict,
        /// An unclosed `[` is a literal `[`; an unknown class is still an error.
        lenient,
    };

    /// What one `?` or one bracket consumes.
    pub const Unit = enum {
        /// One byte.
        byte,
        /// One UTF-8 scalar; each byte of an ill-formed sequence is a unit
        /// of its own that no scalar or other byte equals.
        utf8,
    };

    /// Whether a `.` that begins a component is hidden from wildcards.
    pub const LeadingDot = enum {
        /// `.` is like any other unit.
        ordinary,
        /// A `.` at the start of the subject or right after a separator is
        /// matched only by a literal `.`. `*`, `?`, brackets and `**` never
        /// match it, and a `*` standing at it matches nothing there, not
        /// even the empty run (`fnmatch` with `FNM_PATHNAME | FNM_PERIOD`).
        explicit,
    };

    /// git's `wildmatch()` with `WM_PATHNAME`: `.gitignore`, attributes,
    /// `:(glob)` pathspecs.
    pub const git: Syntax = .{};
    /// git's `wildmatch()` without `WM_PATHNAME`; `fnmatch` with no flags.
    pub const git_text: Syntax = .{ .separator = null };
    /// EditorConfig path globs: `**` crosses separators anywhere; integer ranges.
    pub const editorconfig: Syntax = .{ .globstar = .anywhere, .globstar_slash = true, .braces = true, .numeric_ranges = true, .unit = .utf8, .basename = true, .root_slash = true, .single_brace_literal = true, .bracket_separator_literal = true };
    /// Path globs with braces over UTF-8 scalars.
    pub const glob: Syntax = .{ .braces = true, .unit = .utf8 };
    /// `fnmatch(FNM_PATHNAME | FNM_PERIOD)` in a UTF-8 locale.
    pub const posix: Syntax = .{ .globstar = .off, .brackets = .lenient, .unit = .utf8, .leading_dot = .explicit };
};

/// How letters compare.
pub const Case = enum {
    /// Units compare as they are.
    sensitive,
    /// A-Z equal a-z everywhere: literals, escapes and bracket members. A
    /// bracket matches a letter when it holds either case of it.
    ascii,
    /// git's `WM_CASEFOLD`, including its quirks: an escaped letter and a
    /// bracket member compare unfolded against the folded subject, so `\A`
    /// and `[A]` match nothing, while a range is retried with the upper-case
    /// letter, so `[A-Z]` matches `q`.
    ascii_git,
    /// Default Unicode simple case folding over UTF-8 scalars. Does not
    /// normalize or expand characters; invalid UTF-8 bytes stay distinct.
    unicode,
};

/// What a pattern means, given with each call or compile.
pub const Options = struct {
    syntax: Syntax = .git,
    /// NFC composed scalar units for literals, classes and subjects. Exact by default.
    normalization: enum { exact, nfc } = .exact,
    case: Case = .sensitive,
    /// A pattern holding no separator byte matches the last component at any
    /// depth, as gitignore matches a slash-free line: it is read as `**/`
    /// followed by the pattern. No effect in text mode.
    anywhere: bool = false,
    /// Filled when a call returns `error.InvalidPattern` or
    /// `error.PatternTooLong`.
    diagnostics: ?*Diagnostics = null,
};

/// Where and why a pattern was refused.
// aegis: no-danger: docs/design.md#safety-boundaries; the diagnostic reports one source byte offset, never a program or entry index.
pub const Diagnostics = struct {
    /// Byte offset in the pattern where the problem was found.
    offset: usize = 0,
    reason: Reason = .too_long,

    /// Why a pattern was refused.
    pub const Reason = enum {
        /// A `[` with no closing `]` under `Syntax.Brackets.strict`.
        unclosed_bracket,
        /// A `[:name:]` naming no POSIX class.
        unknown_class,
        /// A `\` with nothing after it.
        trailing_escape,
        /// A `{` with no closing `}`.
        unclosed_brace,
        /// A `}` with no opening `{`.
        unmatched_brace,
        /// An extglob group has no closing `)`.
        unclosed_extglob,
        /// Complement extglob cannot be represented by the regular parser.
        unsupported_extglob,
        /// A bound is outside signed 64-bit integers, or lower exceeds upper.
        invalid_range,
        /// The pattern needs more room than the call has.
        too_long,
        /// A normalized bracket member is not one composed scalar.
        multi_scalar_member,
    };
};

/// Why a pattern cannot be matched.
pub const PatternError = error{
    /// The pattern is malformed; `Diagnostics` says where.
    InvalidPattern,
    /// The pattern needs more room than the call has.
    PatternTooLong,
};
