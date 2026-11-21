# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Development on shakedown 53158a4. The syntax corpus test runs through `shakedown.corpus.rows`, each row with a leak-counting allocator that takes no stack trace per allocation: in Debug the testing allocator's trace per allocation made the test take 22.7 s, close enough to the test runner's 120 s bound that a loaded machine ran it out, and it now takes 2.6 s.

## [0.4.1] - 2026-11-21

### Changed

- Pins aegis 0.4.0 and xenoglyph 0.6.1.

## [0.4.0] - 2026-11-21

### Breaking

- `Composed.init` (`glob.Composed.init`) takes the text alone: the parser's escape flag, which a caller had to pass as `false`, stays the parser's. `Composed` is its own type (`normal.Composed`, over the parser's `normal.Iterator`), with `init`, `next` and `at` as before and the iterator's working state no longer in its fields: `Composed.raw`, `Composed.ordered`, `Composed.starter` and `Composed.last_class` (`glob.Composed.raw`, `glob.Composed.ordered`, `glob.Composed.starter`, `glob.Composed.last_class`) are gone, and a `glob.Composed` literal no longer requires `raw` (it requires `inner`; `Composed.init` builds one).
- `walk.Matcher` has a third case, `everything`, a walk that only an ignore stack narrows: a switch over a matcher names it.
- `Walk.open`, `Walk.next`, `Walk.OpenError` and `Walk.NextError` (`walk.Walk.open`, `walk.Walk.next`, `walk.Walk.OpenError`, `walk.Walk.NextError`), and `expand` (`walk.expand`), fail with `ignore.FileError` too, as the entry below says.
- `Set.Cache.parts` (`glob.Set.Cache.parts`) is a slice of the public `Set.Cache.PartCache`, and `Set.parts` of the public `set.Part`, where both types were private; `normal.Iterator.raw` is of the public `normal.Raw`.
- `ignore.Checker.root` is an `aegis.own.Unowned(std.Io.Dir)`, the caller's directory it never closes; `ignore.Checker.init` still takes the `std.Io.Dir`.
- `Walk.OpenError` (and so `NextError`) holds `ignore.FileError`: a walk with `Options.ignore` reads each directory's ignore files and fails with what reading one did. `Matcher` gains `everything`, so an exhaustive switch over it needs that arm.

### Added

- Properties for the README's promises over generated patterns: a walk returns exactly the paths of the tree that match, each once; every match starts with its pattern's literal prefix and its base; captures say what `matches` says, change nothing on a nonmatch and lie in the subject. Each fails on a planted fault.
- `ignore`: ignore files stacked as git stacks them (`dir.c`), proven against git 2.56.0's t0008 and t3001 and fuzzed against git's own list walk.
  - `ignore.Stack` holds levels in three `Group`s, ranked lowest first: files (`core.excludesFile`, then `info/exclude`), each directory's files, and a command line's patterns. Within a group the later level wins, and within a level the last matching line.
  - Levels are added by `addText` (line grammar), `addPatterns` (as given, `clean -e`), `addFile`, and `addDirectory` (`Options.file_names`, read with no follow).
  - `match` decides a path alone, and `matchPath` decides it with its parents, an excluded parent deciding. Both return `Match` with the deciding `Origin` (source, line, text, negated), check-ignore -v's line.
  - Files are read through aegis with a stated limit (`Options.max_file`, git's 100 MiB). An in-tree file is opened without following a link, so a link is refused by the open itself.
  - `Options.unreadable = .skip` is git's warn-and-go-on. Each file skipped is listed in `Stack.skipped` with its reason (`FileTooLarge`, `LinkRefused`, or the error).
  - `ignore.Checker` asks one path at a time outside a walk. It reads each directory's files the first time a path below it is asked about, and nothing inside an excluded directory. `Checker.toStack` hands the stack back with every level read, for a caller that lent its own.
- `Walk.Options.ignore`: a walk reads each directory's ignore files through the handle it holds, pushes them as it enters and pops them as it leaves, and neither returns nor enters an excluded entry. `Matcher.everything` walks every path the stack lets through.

### Changed

- sweep's own development holds it to the family's policy: `"policy": "family"` in ci/preflight.json, beside the hardened profile ci/workflow.json already declares; the hardened and hardened-tsan legs pass.
- The package a project fetches holds no test data: the UCD's NormalizationTest.txt and CaseFolding.txt, the pattern corpora (`syntax.tsv`, `captures.tsv`) and the Unicode licence that covers them move from `src/` to `testdata/`, outside `build.zig.zon`'s paths, and the tests read them through the development build's `testdata` module. A fetch is 144 KB compressed and 0.6 MiB unpacked, where it was 644 KB and 3.5 MiB.
- The Unicode data is xenoglyph's: sweep depends on xenoglyph (94cb967, on the same aegis f52eabe), and its own generated NFC and case-folding tables (`src/composition.zig`, `src/fold.zig`) and their generators (`tools/`) are gone. Composition keeps original offsets and malformed bytes as before, and a folded bracket range closes orbit by orbit through `xenoglyph.case.nextFolding`. `foldCase` and `Composed` are unchanged; the UCD's conformance files still test both.
- Under `.case = .unicode` a compiled pattern's bracket no longer matches a code that folds with no member: `[Ɖ-ɓ]` (U+0189–U+0253) matched `ƈ` (U+0188). The automaton's unit classes are looked up by a subject code's fold, but a class starting at a code that folds elsewhere was judged by that fold: here Ƀ brings ƀ (U+0180) in, a class starts at Ɓ (U+0181), which folds to ɓ in the range, and every code up to U+0188 matched with it. A class now starts at, and is judged by, its first code that folds to itself. The bracket-range property found it; its three shrunk cases are kept as regressions.
- On FreeBSD and NetBSD a symbolic link refused by a no-follow open (`Links.refuse`, `follow_symlinks = false`) is `error.LinkRefused` or skipped as on Linux and macOS, where it was `error.Unexpected`: those kernels refuse `O_NOFOLLOW` on a link with EMLINK and EFTYPE, which std does not name, so there the name is looked at, unfollowed, and only a link counts as refused. Development on preflight's ci-standard 158c176.
- Pins aegis f52eabe, still 0.2.4 (its addition: `id.raws`), the one aegis the family builds on; development on preflight's ci-standard f991816 and shakedown 327bc61. Nothing this package calls changed.
- Development on preflight's ci-standard 9c18016 and shakedown b99b768. The property that `leadsTo` equals brute force also tries `é`'s two bytes alone: read by bytes, `[é]` is a bracket of either byte and matches a one-byte name, which `leadsTo` saw and the brute force did not try. The fuzzer's case is kept as a regression, with a test of the bracket by itself.
- Pins aegis dc3ed602, still 0.2.4; development on preflight's ci-standard 0990716 and glint 0.8, and shakedown ed5a873. The ignore files are read in one input seam (`src/input.zig`); the lazy automaton's tables are placed in its one allocation by aegis's `parts.Block`, each on a cache line, with no conversion of its own; std's asserts are aegis contracts, kept in every build.
- Pins aegis c8982a8, still 0.2.4: six additive commits after 3c0b13e (the role declarations a linter reads, `lint_rules`), the aegis the development build's preflight selects. Nothing sweep calls changed.
- aegis 0.3, which has one way to lend: `ignore.Checker` holds the caller's root as the `std.Io.Dir` itself, lent by value, which it never closes. Pins aegis breaking-0.3 (7bdb587) and shakedown on it.
- Pins aegis 0.3.0 and xenoglyph 0.6.0.

## [0.3.0] - 2026-10-27

### Breaking

- `Walk.frames`, private, holds pointers to frames that live in the walk's own pool, each frame's directory with one owner (aegis's `own.OwnedIo`), where it held the frames by value and their handles bare. A walk is used as before.

### Changed

- Under the aegis pack on aegis 0.2.1: the lazy automaton's arrays are placed in its line-aligned memory through one checked conversion (the memory's declared alignment at compile time, each part's offset asserted); a pattern's in-place capacities are read from `match.Storage`'s type, not from storage still undefined; `normal.Ordered` and `Set.Prefixes`, which public functions take, are public types. Escapes that named no reason the pack knows, or suppressed nothing, are gone.

## [0.2.5] - 2026-10-24

### Changed

- Development: the lint gates the aegis pack, glint's A001-A005.
- Development: the suite runs under the release tier's hardened profile (`bay hardened`, `bay hardened-fuzz`, `bay hardened-tsan`).
- Pins aegis 0.1.17.

## [0.2.4] - 2026-10-15

### Added

- `gitignore.parsePattern`: one pattern as given, git's `parse_path_pattern`, with none of an ignore file's line grammar (no comment, trailing spaces or CR); `parseLine` is that after the line's own steps. What `git clean -e` and `git ls-files -x` add.

## [0.2.3] - 2026-10-14

### Changed

- Pins aegis 0.1.8.

## [0.2.2] - 2026-10-13

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.2.1] - 2026-10-12

### Changed

- Pins preflight 0.3.4 and shakedown 0.2.5.

## [0.2.0] - 2026-10-11

### Breaking

- sweep is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, example, checks and benchmarks are the development build's (`bay test`, `bay bench`). A project that depends on sweep fetches only aegis, as before.
- `Set.Builder.add`, `Set.first`, `Set.last` and `Set.Ancestors.Step.last`
  return `Set.Index` instead of raw `u32`; `Set.all` appends to
  `std.ArrayList(Set.Index)`. Use `index.raw()` at caller array boundaries.
- `Set.len` returns `Set.Count`, and `Set.Cache.Options.capacity` takes
  `Set.Bytes`; construct byte capacity with `Set.Bytes.fromRaw`.
- `Set.Builder.build` returns named `Set.BuildError`, including
  `PatternTooLong` when combined construction arithmetic or the emitted
  program exceeds its limit.
- Runtime dependencies now include the std-only aegis safety library.
- `sweep.glob` and `sweep.walk` are no longer build modules: the package
  exposes the one module `sweep`, and both are namespaces in it. Code that
  imports `sweep` is unchanged (`sweep.glob.Pattern`, `sweep.Walk` and every
  other path stay); code that did `b.dependency("sweep", ...).module("sweep.glob")`
  or `@import("sweep.walk")` imports `sweep` and uses `sweep.glob` or
  `sweep.walk`.

### Added

- `sweep.glob` (pure computation) and `sweep.walk` (filesystem expansion) are
  namespaces of the `sweep` module, and `sweep` reexports their names. A
  program that only matches never analyses the walk.
- Distinct program positions, source-byte offsets and allocation element counts;
  ranged accept encoding and all-mode checked construction/capture arithmetic.
- Check individual, combined and tagged construction arithmetic in every mode;
  report combined-program exhaustion as `PatternTooLong` and preserve entry
  issuance after a failed add.
- Optional NFC scalar matching, parsed literal and class normalization, and the
  allocation-free `Composed` iterator using Unicode 18 data.
- Refuse normalized class members that remain several scalars.
- An alternate separator spelling for native path syntax.

### Changed

- The Smith fuzz tests are shakedown `check` properties.
- A `Set` of at most 32 entries per reading that literal strategies and the direct reader decide answers `any`, `first`, `last` and `all` by asking the entries one at a time, stopping where the mode has its answer; the hashed tables and the lazy DFA serve larger sets, `ancestors` and `leadsTo`. Twelve attribute-style entries cost 76 ns a path in `all` where they cost 215, and 7 in `any` where they cost 155; thirty ignore-style entries cost 135 where they cost 196.
- `**/lit/**` and `**/*` (a lone `*` at any depth) are decided by a literal comparison, as `**/lit` and `lit/**` are; the first searches a block of the subject at a time.
- `Set.Cache.Options.capacity` is the most a reading's cache takes, no longer at least 64 KiB: a reading takes 8 KiB and 2 KiB an entry at most, and one with no automaton takes nothing, all in one allocation. Making a cache for a small set cost 1.7 to 8 microseconds, mostly a mapping of memory it never used, and costs 30 nanoseconds.
- Building a `Set` takes a quarter to a third less time from thirty entries up, as the unit classes of a program are split once for each literal it holds, and 0.3 microseconds more (1.06 to 1.37) for three entries, the price of the list a scan keeps.
- Ordinary epsilon closure skips extglob cycle tracking, and NFA steps fold a unit once across all active threads.
- DFA construction reuses canonical unit representatives; ordinary parsing skips disabled numeric, extglob and capture work.
- Direct matching consumes standalone component stars before general execution and scans each remaining component's star segments with one local bound.
- Plain compiled byte patterns reuse validated direct execution; fixed-width star tails and basename prefixes avoid DFA construction.
- Small compilations use stack construction, and Sets hash component prefixes, including patterns longer than `Pattern.max_units`.
- One-shot literal rejection skips dialect setup when the first byte decides the result.
- CI gates glint's A004 (raw aegis scalar operations) and Z026 (a discarded error) through the `glint` object of `ci/preflight.json`, over source, tests, benchmarks, examples and CI programs; the retired exception files are gone.

- `foldCase` exposes the Unicode 18 default simple scalar mapping used by
  `Case.unicode`, so filesystem consumers share one case-folding owner.

- `Walk` and `expand`: Pattern/Set filesystem expansion with invariant-base traversal, pruning, hidden-entry and symlink policies, cycle checks and global lexical ordering.
- `Syntax.editorconfig`, signed 64-bit numeric intervals, regular extglobs and Unicode 18.0.0 simple folding with `Case.unicode`.
- `Pattern.captureCache` and `Pattern.captures`: optional capture execution with reusable per-thread scratch and byte offsets.

- `match(pattern, subject, options)`: whether a glob matches a whole subject, with no allocation, in time linear in the subject.
- `Syntax` with the presets `git`, `git_text`, `glob` and `posix`, and the fields `separator`, `globstar` (`off`, `component`, `anywhere`), `escape`, `brackets`, `braces`, `unit` and `leading_dot`; `Case` with `sensitive`, `ascii` and git's `ascii_git`; `Options.anywhere`; `Diagnostics` for a refused pattern.
- `Pattern`: compiled once, up to `Pattern.max_units` units, with `matches`, `ancestor`, `leadsTo` and `base`; queries share nothing between threads.
- `Set`: many patterns in one pass, with `any`, `first`, `last`, `all`, `ancestors` and `leadsTo`, directory-only entries, and a per-thread `Set.Cache` whose `stats` count states, clears and fallbacks.
- `gitignore.parseLine`: one line of an ignore file, read as git reads it.
- `isSpecial`, `literalPrefix` and `escape`.
- Pins aegis 0.1.0.

[Unreleased]: https://github.com/pedronaugusto/sweep/commits/main
