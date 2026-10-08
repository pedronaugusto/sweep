# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Ordinary epsilon closure skips extglob cycle tracking, and NFA steps fold a unit once across all active threads.
- DFA construction reuses canonical unit representatives; ordinary parsing skips disabled numeric, extglob and capture work.
- Direct matching consumes standalone component stars before general execution and scans each remaining component's star segments with one local bound.
- Plain compiled byte patterns reuse validated direct execution; fixed-width star tails and basename prefixes avoid DFA construction.
- Small compilations use stack construction, and Sets hash component prefixes, including patterns longer than `Pattern.max_units`.
- One-shot literal rejection skips dialect setup when the first byte decides the result.

### Added

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
