# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `match(pattern, subject, options)`: whether a glob matches a whole subject, with no allocation, in time linear in the subject.
- `Syntax` with the presets `git`, `git_text`, `glob` and `posix`; `Case` with `sensitive`, `ascii` and `ascii_git`; `Options.anywhere`; `Diagnostics` for a refused pattern.
- `isSpecial`, `literalPrefix` and `escape`.

[Unreleased]: https://github.com/pedronaugusto/sweep/commits/main
