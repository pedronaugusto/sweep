# Parsed normalization seam and shared folding owner

Work in progress. The normalization seam is not implemented yet.

Baseline is published sweep main
`ca2549467b9e3830f75eb81ec5e1072d8e3c615a`, exact-head green merge CI
`37766731595`. The book sweep design and review F07 leave normalization
unit semantics for an owner decision. No change to git sensitive or
ascii_git semantics is intended.

## Ownership decision

Sweep owns Unicode 18 default simple folding and its generated table.
`foldCase(code: u21) u21` exposes the exact engine mapping without a second
folder. It excludes expanding/Turkic mappings and normalization; non-scalar
codes remain distinct. Lookout owns root/directory filesystem identity and
normalization policy, kernel spelling, and caller filter preference.
Only sweep may interpret glob syntax.

The public API has table-wide agreement and idempotence tests, including
invalid-byte codes, sigma, sharp S and dotted I. Tests were introduced
before the export and refused to compile because the API did not exist.
Raw test evidence is retained alongside this report.

## Pending owner contract

Before building the seam, choose original scalars, canonically composed
scalars, or normalized decomposed scalars (with expanding classes refused).
The `[é]` class cannot become independent `e` and accent members. Wildcard
boundaries, ranges, negation and escapes must follow the same explicit
contract, while git defaults stay exact and matching remains bounded.

Shakedown repin: published main `d5d19d39bc60cec59456aca947a3a7b484b87318`,
verified green CI `37768627963`. Preflight at inspected published main
`9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`, green CI `37711386950`.
Only published mains were considered, never another worker's branch.

No hot matching path has changed in this independent API export.
Before/after hot-path timing and full syntax regression coverage are
required when normalization is implemented. The book sweep migration
paragraph's raw-pattern folding and its LATER Unicode-folding status
are stale against the current implementation and this ownership decision.

## Local verification

`zig build test -Dci-lint=false -Dtest-filter='public simple folding'`:
3/3 tests passed (including the assembly test); raw output in
`fold-after.txt`. The initial missing-export compile failure is in
`fold-before.txt`. `zig build lint check`: all steps succeeded; raw
evidence in `checks.txt`. All commands used Zig 0.17.0 for subprocesses too.

CI matrices were regenerated from `zig build plan -- --tier` for fast,
merge and release through pinned preflight; they match the existing caller
workflow exactly. Raw generated output is in `ci-*-plan.txt`.

No semantic normalization choice has been made, no second folding engine
has been introduced, and no final merge gate or landing is claimed.
The independent API export can be reviewed while the owner contracts
remain pending.
