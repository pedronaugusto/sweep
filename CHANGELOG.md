# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- `Set.Builder.add`, `Set.first`, `Set.last` and `Set.Ancestors.Step.last`
  return `Set.Index` instead of raw `u32`; `Set.all` appends to
  `std.ArrayList(Set.Index)`. Use `index.raw()` at caller array boundaries.
- `Set.len` returns `Set.Count`, and `Set.Cache.Options.capacity` takes
  `Set.Bytes`; construct byte capacity with `Set.Bytes.fromRaw`.
- `Set.Builder.build` returns named `Set.BuildError`, including
  `PatternTooLong` when combined construction arithmetic or the emitted
  program exceeds its limit.
- Runtime dependencies now include the std-only aegis safety library.

### Added

- `sweep.glob` and `sweep.walk` build modules expose the existing computation
  and filesystem concerns independently; `sweep` reexports the same identities.
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

[Unreleased]: https://github.com/pedronaugusto/sweep/commits/main
