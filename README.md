# sweep

sweep matches path globs in Zig: git's wildmatch exactly, and the common glob
dialects beside it. Matching time is linear in the subject for every pattern,
by construction: there is no backtracking and no recursion anywhere.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/sweep`, then obtain the `sweep` module through
`b.dependency` and add it to your executable's imports. sweep has no dependencies.

## Usage

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const sweep = @import("sweep");

// git's dialect: `*` stays in one component, `**/` spans any number.
std.debug.assert(try sweep.match("src/**/*.zig", "src/a/b/c.zig", .{}));
std.debug.assert(!try sweep.match("src/*.zig", "src/a/c.zig", .{}));
// gitignore's rule for a pattern with no separator: any depth.
std.debug.assert(try sweep.match("*.o", "build/x/y.o", .{ .anywhere = true }));
```
<!-- END GENERATED -->

## Design

A pattern compiles to a Thompson automaton over units, bytes or UTF-8 scalars,
whose epsilon edges all point forwards. A set of threads is closed in one sweep
in index order, so each automaton state is visited at most once per subject
unit: O(n·m) for n units and m states, asserted in safe builds. `match` builds
the automaton on the stack, in about 16 KiB, and allocates nothing.

## Scope

- No directory walking yet.
- No reading of ignore or attribute files; a caller splits the lines.
- No Unicode case folding or normalisation: fold both sides first.
- No `\` as a separator: callers turn Windows paths into `/` paths first.
- No negated patterns and no include or exclude policy.

## Testing

`zig build test` runs the suite and the usage example.

## Licence

MIT. See [LICENSE](LICENSE).
