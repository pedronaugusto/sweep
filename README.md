# sweep

sweep matches path globs in Zig: git's wildmatch exactly, and the common glob
dialects beside it, for one pattern or many at once. Matching time is linear
in the subject for every pattern, by construction: there is no backtracking and
no recursion anywhere, the parser included.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/sweep`, then obtain the `sweep` module through
`b.dependency` and add it to your executable's imports. sweep has no dependencies
and makes no OS calls; it builds for every target, wasm32-freestanding included.

## Usage

`match` answers one question with no allocation:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const sweep = @import("sweep");

// git's dialect: `*` stays in one component, `**/` spans any number.
std.debug.assert(try sweep.match("src/**/*.zig", "src/a/b/c.zig", .{}));
std.debug.assert(!try sweep.match("src/*.zig", "src/a/c.zig", .{}));
// gitignore's rule for a pattern with no separator: any depth.
std.debug.assert(try sweep.match("*.o", "build/x/y.o", .{ .anywhere = true }));
// Braces and UTF-8 scalars in the glob dialect.
std.debug.assert(try sweep.match("*.{c,h}", "main.h", .{ .syntax = .glob }));
```
<!-- END GENERATED -->

A `Pattern` is compiled once for many subjects, and answers the questions a walk
asks:

<!-- BEGIN GENERATED zig build docs -- pattern -->
```zig
const sweep = @import("sweep");

var pattern: sweep.Pattern = try .compile(gpa, "src/**/test_*.zig", .{});
defer pattern.deinit();
std.debug.assert(pattern.matches("src/net/test_io.zig"));
// Walking: start at the literal base, enter only what can lead to a match.
std.debug.assert(std.mem.eql(u8, pattern.base(), "src"));
std.debug.assert(pattern.leadsTo("src/net"));
std.debug.assert(!pattern.leadsTo("docs"));
```
<!-- END GENERATED -->

A `Set` matches many patterns in one pass. With `gitignore.parseLine` it is an
ignore file:

<!-- BEGIN GENERATED zig build docs -- set -->
```zig
const sweep = @import("sweep");

const lines = [_][]const u8{ "*.log", "!keep.log", "build/" };
var builder: sweep.Set.Builder = .init(gpa);
defer builder.deinit();
var negated: [lines.len]bool = undefined;
for (lines) |line| {
    const parsed = sweep.gitignore.parseLine(line) orelse continue;
    negated[try builder.add(parsed.pattern, parsed.entry)] = parsed.negated;
}
var set = try builder.build();
defer set.deinit();
// One cache per thread; queries allocate nothing.
var cache: sweep.Set.Cache = try .init(gpa, &set, .{});
defer cache.deinit();
// The last matching line decides, and a negated line re-includes.
const ignored = struct {
    fn f(s: *const sweep.Set, c: *sweep.Set.Cache, n: []const bool, path: []const u8, kind: sweep.Kind) bool {
        return if (s.last(c, path, kind)) |i| !n[i] else false;
    }
}.f;
std.debug.assert(ignored(&set, &cache, &negated, "x/debug.log", .file));
std.debug.assert(!ignored(&set, &cache, &negated, "x/keep.log", .file));
std.debug.assert(ignored(&set, &cache, &negated, "build", .dir));
// Every parent in one pass: a file under an ignored directory is ignored.
var it = set.ancestors(&cache, "build/out/keep.log", .file);
while (it.next()) |step| {
    if (step.last) |i| if (!negated[i]) break;
}
```
<!-- END GENERATED -->

## Design

A pattern compiles to a Thompson automaton over units, bytes or UTF-8 scalars,
whose epsilon edges all point forwards. A set of threads is closed in one sweep in
index order, so each automaton state is visited at most once per subject unit:
O(n·m) for n units and m states. The NFA counts the states it closes, and a set's
lazy DFA its transitions and the states it closes to build new ones, and both
assert that bound in safe builds; a literal comparison or the eager DFA takes one
step a unit. The tests run the bound against inputs that make backtracking
matchers exponential.

Three executors sit on top of the automaton. A pattern a few byte comparisons
decide (`src/main.zig`, `*.c` at any depth, `build/**`, `**/node_modules`) never
runs it. Others are checked against the literal prefix and suffix every match
needs, then run on a small DFA built at compile time (64 states at most); the
NFA is the fallback that keeps the bound. A set hashes the literal entries (whole
paths, base names, extensions, directory prefixes, path suffixes) and runs the
rest as one lazy DFA whose states a per-thread cache builds on first use.

`match` reads a plain pattern straight from its text, only as far as the answer
needs: bytes, `?`, `*`, `**`, and brackets of bytes and ranges with case kept, with
no escape or brace. Stars split a component into segments; a star before the last
takes exactly what that segment leaves, and a star before any other the least it
can, so a component is read once, and the last `**` over components is the one
retry point, which keeps the bound. Any other pattern it builds as the automaton on
the stack, in about 16 KiB. Neither allocates, and `match` is inline, so options
known at compile time choose the reader at compile time. `match` takes patterns up
to 1024 units with up to 64 brackets, whichever reader would take them; a longer one
is `error.PatternTooLong` and compiles as a `Pattern`. A `Pattern` takes up to
8192 units (`Pattern.max_units`) and runs its NFA on the caller's stack, in about
8 KiB, so any number of threads query it with nothing shared; a longer pattern is
`error.PatternTooLong`, and a `Set` of one entry takes it. `Pattern` and `Set`
allocate when they are built and never after; a `Set.Cache` allocates once at
`init`, clears itself when full, and finishes a query that keeps clearing it on the
NFA, so its capacity changes speed, never answers or the bound. `cache.stats()`
counts the states built, the clears and the fallbacks.

### Dialects

One parser reads every dialect; each `Syntax` field is independent:

| Field | Meaning |
|---|---|
| `separator` | `*`, `?` and brackets never match it, and `**` standing between two of them is a globstar. `null` is text mode: `*` matches anything. |
| `globstar` | `.component`: `**` as a whole component matches zero or more components, and is `*` anywhere else. `.anywhere`: every `**` matches any run. `.off`: `**` is `*`. |
| `escape` | `\x` matches `x`, inside brackets too. A trailing lone `\` is an invalid pattern. |
| `brackets` | `.strict`: an unclosed `[` or an unknown `[:class:]` is an invalid pattern. `.lenient`: an unclosed `[` is a literal. `.none`: `[` is a literal. |
| `braces` | `{a,b}`, nested, empty alternatives allowed; compiled as alternation, never expanded. |
| `unit` | `.byte`, or `.utf8`: `?` and a bracket take one scalar, and each byte of an ill-formed sequence is a unit of its own. |
| `leading_dot` | `.explicit`: a `.` starting a component is matched only by a literal `.` starting a pattern component. |

| Preset | Equals |
|---|---|
| `Syntax.git` | git's `wildmatch` with `WM_PATHNAME`: `.gitignore`, attributes, `:(glob)` pathspecs |
| `Syntax.git_text` | git's `wildmatch` without it, and `fnmatch` with no flags |
| `Syntax.glob` | path globs with braces over UTF-8 scalars |
| `Syntax.posix` | `fnmatch(FNM_PATHNAME \| FNM_PERIOD)` in a UTF-8 locale |

`Case.ascii` folds A–Z everywhere. `Case.ascii_git` is git's `WM_CASEFOLD` exactly,
quirks included: an escaped letter and a bracket member compare unfolded, so `\A`
and `[A]` match nothing while `[A-Z]` matches `q`.

`Options.anywhere` is gitignore's basename rule: a pattern holding no separator
byte matches the last component at any depth.

Braces follow their expansion: `{**/a,b}` holds a globstar and `x{**,y}` does not,
since `x` comes first. A `**` is two or more `*` written together, so `*{*,a}` is
two stars.

Where git aborts on a malformed bracket it returns no match; sweep refuses the
pattern with `error.InvalidPattern` and fills `Options.diagnostics` with the byte
offset and the reason.

## API

| Call | Does |
|---|---|
| `match(pattern, subject, options)` | Whether a pattern matches all of a subject, with no allocation |
| `Pattern.compile(gpa, pattern, options)` | A pattern of up to 8192 units compiled once; nothing stays borrowed |
| `pattern.matches(subject)` | Whether it matches |
| `pattern.ancestor(subject)` | The end of the shortest prefix ending at a separator, or the whole subject, that matches |
| `pattern.leadsTo(dir)` | Whether anything below `dir` could match; exact, so a walk can prune by it |
| `pattern.base()` | The literal leading directories a walk of the pattern starts from |
| `Set.Builder.add(pattern, entry)` | Adds an entry and returns its index; `entry.dir_only` matches directories only |
| `set.any`, `first`, `last`, `all` | Whether any entry matches; the lowest or highest matching index; every index, ascending |
| `set.ancestors(cache, path, kind)` | One pass over every prefix of a path: the last entry matching each, and whether anything below can |
| `set.leadsTo(cache, dir)` | Whether anything below `dir` could match |
| `gitignore.parseLine(line)` | One ignore-file line: its pattern, `Set.Entry` and whether it is negated |
| `isSpecial`, `literalPrefix`, `escape` | Which bytes are special; the plain leading run; a literal written as a pattern |

A set's entries share one separator (`error.SeparatorMismatch` otherwise); each has
its own syntax, case and `anywhere`. A `Set` is immutable and any number of threads
may query it, each through a `Set.Cache` of its own. Negation and include or
exclude policy are the caller's: gitignore is `if (set.last(...)) |i| !negated[i]`.

## Scope

- No directory walking yet; `base`, `leadsTo` and `ancestors` are what a walk needs.
- No reading of ignore or attribute files: `gitignore.parseLine` reads one line, and
  files, levels and precedence are the caller's.
- No Unicode case folding or normalisation: fold both sides first.
- No `\` as a separator: turn Windows paths into `/` paths before matching, and
  pass `.escape = false` for patterns written with `\`:
  `for (path) |*c| if (c.* == '\\') c.* = '/';`
- No negated patterns, no `!(...)` and no other extglob forms.
- No translation to regular expressions and no brace expansion to strings.

## Platforms

Every target Zig supports. sweep uses only `std.mem`, `std.hash` and an
`Allocator`; behaviour is the same everywhere.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.

## Testing

`zig build test` runs the suite and the usage example. git's own wildmatch test
vectors are committed as data, and a port of git's matcher is the reference: random
patterns and subjects over git's alphabet must get the same answer from sweep in
all four git modes. A naive backtracking matcher, written from the rules above, is
the oracle for every other dialect and case. Compiled patterns are held to the
one-shot matcher executor by executor, the direct reading of plain patterns to the
NFA, `ancestor` and `leadsTo` to brute force, and sets to their entries matched one by one, `ancestors` included, also with a cache
so small that queries finish on the NFA. The step bound is asserted on the shapes
that make backtracking exponential, at 4096 units. Every
allocation failure in building is survived without a leak, queries are counted to
allocate nothing, and eight threads share one set. The properties run on seeded
inputs in every `zig build test`, and under `zig build test --fuzz` they search
further.

`zig build bench` times sweep's own workloads in ReleaseFast: single patterns one-shot
and compiled over a synthetic tree, compile times, set queries at 100 to 10,000 entries,
and the adversarial shapes, each the best of 50 calls. Run from `zig-out/bench`, `bench
--json` prints JSON lines. `zig build test` runs it once at its smallest size with
`--smoke`; CI times nothing.

## Licence

MIT. See [LICENSE](LICENSE).
