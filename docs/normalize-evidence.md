# Parsed NFC matching and shared Unicode ownership

Work in progress toward the public cut. The F07 normalization seam is
implemented; the retired branch's original report is normalize-initial.md.
Published baseline was ca2549467b9e3830f75eb81ec5e1072d8e3c615a (merge
37766731595). The replacement started at published normalize 4531c1a,
verified fast run 37813725470. Pushed history has not been rewritten.

## Accepted contract

Sweep owns grammar, Unicode 18 simple folding and complete NFC composition.
Options.normalization defaults to exact. NFC composes pattern literal runs
and class members after syntax is identified, and iterates subject scalars
with the same data. [é] matches either spelling of é and never e. Question
mark consumes one composed scalar. Ranges, negation and escapes follow the
same scalar contract. Multi-scalar canonical class members are refused at
compile. Git defaults remain exact. Alternate separator syntax handles
Windows paths without a caller rewriting raw glob text.

Full canonical decomposition, ordering, composition exclusions and Hangul
are covered by the official Unicode 18 NormalizationTest corpus. Invalid
bytes remain distinct barriers. Long combining runs use constant scratch
and at most 255 stable ordering passes; matching remains O(n*m), with no
recursion, allocation during queries, or arbitrary combining-length cap.
Composed shares the iterator with filesystem callers; foldCase remains the
single default simple-fold mapping. Filesystem identity policy and original
kernel spelling are the caller's concern, not inferred from Unicode folding.

## Reproduced checks

nfc-before.txt retains the failing-before compile specification. Lookout's
independent F07 regression reproduces the actual raw-pattern corruption.
nfc-after.txt records targeted syntax, corpus, capture, ancestor, mixed set,
invalid-byte, long combining-run and NoResize allocation-failure tests.
git-after.txt records the unchanged git differential cases. nfc-checks.txt
records required lint and compile checks. The old reports and raw folding
regressions remain beside this report.

## ReleaseFast A/B

Seven interleaved rounds, with alternating acquisition order, on the same
Apple silicon host and Zig 0.17.0. normalization-ab.jsonl retains all
shakedown.bench samples; sweep-ab-final.txt retains the standard workload
runs. Earlier measurements are retained as sweep-ab-raw.txt and
normalization-ab.tsv. Before binaries were built from the published baseline.

Best ns/query, baseline exact → candidate exact → candidate NFC:
ASCII 27.19 → 27.65 → 32.04; accented class 38.08 → 38.45 → 305.26;
Hangul 32.56 → 32.85 → 207.83; reordered combining 2.18 → 2.11 → 274.99.
The before/exact Unicode rows return no-match for decomposed input; the NFC
rows return match. Their extra work buys the accepted normalization contract,
not an equivalent-answer speed claim.

A/B first found large exact-loop and class regressions. They were fixed by
specializing parsed normalization, keeping the reading layout compact,
separating normalization scratch from ordinary set queries, and selecting
a byte reader once. Final standard set any (100/1k/10k entries), best ns/path:
184.44 → 187.92; 241.51 → 243.80; 282.73 → 286.19. Ancestors improves:
415.01 → 407.07; 488.40 → 477.45; 539.60 → 528.95. Small remaining any
changes (0.9–1.9%) are reported explicitly; timings are not correctness gates.
Compiled *.[ch] is 10.23 → 9.92 ns/path. No claim of a speed win on every row.

## Pins and book drift

Shakedown is test/benchmark-only at green published main
9357a9ab398ac25fa8a408a71e77a124bc51d311 (merge 37818062956); preflight
remains green published main 9af905ed85cab6dbb19d9431c65ee3f41fbaa74d.
No owner-fixes branch is pinned. Source and report follow the accepted book
mission at 309bd974a045b64f93863b7931831fe9d0712910. The older book design's
raw-pattern folding migration and LATER folding/composition account are stale;
no book edits were made. There are no remaining semantic owner decisions.
