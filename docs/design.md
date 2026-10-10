# Architecture

sweep owns glob syntax and matching. Its runtime closure is sweep → aegis → std.
Matching,
captures and Unicode transforms are pure computation; filesystem expansion is
an optional layer above them that accepts the caller's `std.Io` per call.
Ignore-file precedence, filesystem identity, root case policy and locale rules
belong to callers. Callers choose equivalence options; sweep applies them after
parsing syntax, because rewriting glob text can change its language.

This describes the implementation in this repository. Change it with the code
when an owner, invariant or decision changes. The public cut and family-wide
validation remain work in progress; this document does not declare a release
or a performance target met.

## Layers and owners

[ci/layers.zig](../ci/layers.zig) checks the production import graph. Layers
below are ordered from lowest to highest; imports stay within a layer or go
downward. Paths are under `src/`. Tests have their own dependency graph;
shakedown and preflight are lazy test/build dependencies, outside a consumer's
runtime closure. The package is one build module, `sweep`, with the namespaces
`sweep.glob` and `sweep.walk`. A second module would buy something only if a part
had dependencies other users should not fetch or must not link something, and
neither part does: aegis is the package's, and the walk adds only `std.Io`, which
Zig analyses where a program names it. A program that only matches therefore
never compiles the walk, and `zig build check-freestanding` proves the matching
calls build for wasm32-freestanding. The layering below is enforced at file
level by [ci/layers.zig](../ci/layers.zig), not by module boundaries.

| Layer | Files and responsibility |
|---|---|
| Units and syntax | `syntax.zig` owns dialects, options and diagnostics; `unit.zig` decodes bytes/scalars and distinguishes malformed bytes; `unicode.zig` and generated `fold.zig` own simple case folding; generated `composition.zig` owns canonical decomposition, combining classes and composition pairs. |
| Normalization | `normal.zig` owns allocation-free canonical composition and original byte boundaries. |
| Classes | `class.zig` owns bracket membership and folded ranges. |
| Automaton | `program.zig` owns Thompson instructions, construction scratch, contexts and the shared subject reader. |
| Parser, execution and literals | `parse.zig` owns grammar and emits instructions; `integer.zig` compiles decimal intervals; `nfa.zig` simulates the program; `direct.zig` reads eligible byte patterns; `strategy.zig` recognizes literal strategies; `helpers.zig` owns syntax helpers. |
| One-shot, DFA states, hashed and scanned literals | `match.zig` owns one-shot stack scratch; `capture.zig` owns tagged execution; `dfa.zig` builds unit partitions and states; `tables.zig` owns literal indexes; `scan.zig` owns the entry list a small reading is asked one by one. |
| Compiled patterns and lazy DFAs | `pattern.zig` owns a compiled Pattern; `lazy.zig` owns set automata and their mutable DFA caches. |
| Sets | `set.zig` owns entry order, immutable partitions and query aggregation. |
| Line grammar | `gitignore.zig` parses a borrowed line; files, levels and precedence stay outside sweep. |
| Walking | `walk.zig` owns traversal state above Pattern/Set pruning. |
| Concern facades | `glob.zig` exposes pure computation as the namespace `sweep.glob`; `walk.zig` exposes optional filesystem expansion as `sweep.walk` and imports only `glob.zig`. |
| Public facade | `sweep.zig` is the module root: it exposes both namespaces and reexports their names at the root, without becoming their state owner. |

`Pattern` owns its compiled program and copied source. Its ordinary queries use
local scratch, so threads share no mutable matching state. `Set` owns immutable
strategies and programs, partitioned by subject reading (units, normalization,
case, separators and leading-dot policy). Entries share primary and alternate separators;
an incompatible boundary grammar returns `SeparatorMismatch`. Each concurrent query
owns a separate `Set.Cache`, which must not outlive its Set. Insertion order
sets entry indices: `first` takes the lowest, `last` the highest, and `all`
returns ascending indices. Proper ancestors count as directories; `dir_only`
entries do not match files. Negation and include/exclude policy stay with callers
because different users require different precedence rules.

`Walk` borrows its root and matcher (including a dedicated Set cache), owns
traversal buffers and directories, and accepts Io per call. A returned path is
borrowed until the next call or teardown; `expand` returns owned paths instead.
Walking uses the literal base and `leadsTo` for pruning, supports filesystem or
lexical order, and checks resolved ancestor paths for directory-symlink cycles
when following links. I/O failures propagate except explicitly skipped missing
entries and link loops. Walking does not implement ignore-file precedence.

## Matching and bounds

Plain byte patterns can run directly from their text. An early subject mismatch
still validates unread syntax, so a malformed pattern cannot become valid
because the subject differs. The direct reader retains component bounds while
scanning star segments to avoid repeated separator searches. Its bounded
component/globstar retries do not introduce recursive or exponential search.

Other patterns compile to a Thompson NFA. Braces are alternation, not expansion
into strings. Ordinary epsilon edges point forward and close in index order.
Regular extglob repetition emits backward edges, marked on the program; only
these programs need visited-context tracking and closure rewinds. Contexts
retain separator and globstar-boundary meaning across alternatives. Each
`(node, context)` closes at most once per input position, giving an asserted
O((n + 1) * m) bound for n subject units and m states, with a fixed context
factor. Parser groups use an explicit stack; matching and parsing do not recurse.

Subject units fold once per NFA step, across all active threads. Raw units stay
available for separator and leading-dot checks: a folding alias cannot become
a separator. DFA partition refinement similarly computes each representative's
canonical unit once. The parser omits optional numeric/extglob/capture checks
when those features are disabled, using the same grammar with compile-time
selection rather than a second parser.

Compiled Patterns use literal strategies, fixed-width star tails or validated
direct execution where eligible. General patterns use an eager DFA capped at
64 states and a bounded transition table, then NFA fallback. Sets hash eligible
exact paths, basenames, extensions, prefixes and suffixes, and run the rest as
one lazy DFA per reading. A single eligible remaining entry can run directly;
its program remains available for ancestor and pruning queries.

A reading of at most 32 entries, each decided by a literal strategy or the
direct reader, is scanned instead: `any`, `first`, `last` and `all` ask its
entries one at a time in insertion order and stop where the mode has its
answer (`last` asks from the end). That costs the entries, a few nanoseconds
each, where the hashes and the DFA cost a step per subject byte, about the
price of asking forty to fifty entries on a path of thirty or forty bytes;
past 32 the tables win. The tables and the
automaton remain for `ancestors` and `leadsTo`, which follow a prefix at a
time. Both executors answer from the same compiled entries, and the tests
compare them with each other and with one compiled pattern per entry.

A Set cache allocates once, at initialization, one block per reading that has
an automaton and nothing for one that has none. A reading takes only what its
entries can use, 8 KiB and 2 KiB an entry (several times the states the
measured sets reach), at most the capacity named, so a small set costs a small
cache whatever the caller allows. Exhaustion clears DFA states; more than
three clears in a query with excessive state construction switches that query
to NFA simulation. Capacity changes speed, never answers or the bound. Statistics
record states, clears and fallbacks. The engine allocates nothing after scratch
setup; `Set.all` can grow the caller's output list. One-shot scratch is bounded
(1024 units, 64 classes and further range/group limits); `Pattern` accepts up to
8192 units. Exhausted construction scratch returns `PatternTooLong`; larger
patterns use an allocated Set rather than unbounded stack storage.

## Dialects and exact defaults

Orthogonal Syntax fields specify separator, globstar, escape, brackets, braces,
units and leading-dot behavior, with additional editorconfig/extglob options.
Presets name combinations without adding hidden matching rules. `globstar` is
an enum (`off`, `component`, `anywhere`) because component and unrestricted
cross-directory stars are different languages. `anywhere` supplies gitignore's
basename rule for separator-free patterns. `a/**` matches `a/`, never `a`.
Paths retain their spelling: dot components and duplicate separators are not
collapsed. An optional `alternate_separator` is recognized by the parser and
subject reader; callers need not rewrite syntax to supply native separators.

Default options use `Syntax.git`, byte units, sensitive case and exact
normalization. `Syntax.git_text` removes the separator restriction.
`Case.ascii_git` preserves git's case-fold quirks: escaped letters and bracket
members compare unfolded against folded subjects, while ranges retry with
upper-case subjects. `Case.ascii` folds consistently throughout syntax instead.
Where git aborts on malformed syntax and returns no match, sweep returns
`InvalidPattern` with optional byte-offset diagnostics. Callers can map that
error to no match. Optional Unicode behavior never changes git defaults.

Regular extglobs support `?()`, `*()`, `+()` and `@()`, with nesting and empty
alternatives; complement `!()` is refused. The editorconfig preset adds root
and basename anchoring, literal singleton braces and signed 64-bit intervals.
Intervals compile into decimal digit blocks instead of enumerating values,
keeping construction independent of the size of the numeric interval.

## Unicode composition and case ownership

sweep owns Unicode 18.0.0 data for both canonical composition and default simple
case folding. `tools/normalize.zig` generates committed `composition.zig` from
canonical Unicode records and full composition exclusions; `tools/casefold.zig`
generates committed C/S folding mappings in `fold.zig`. Consumers run neither
generator and fetch no Unicode runtime dependency. `Composed` exposes the same
composition iterator; `foldCase` exposes the same single-scalar mapping as
`Case.unicode`. Simple folding implies UTF-8 units, without expanding characters
or applying Turkic/locale mappings. Folding alone does not normalize.

`Options.normalization = .nfc` canonically composes pattern and name alike and
implies scalar reading. The parser composes literal runs and bracket members
after recognizing grammar, retaining wildcard, group and separator boundaries.
Escapes quote syntax and participate in their literal run's composition.
`[é]` and `[e` followed by U+0301 `]` each match either spelling of é and never
plain e. `?` consumes one composed scalar, not one byte or one grapheme.
Ranges use composed endpoints and negation tests composed class membership.
A member that remains multiple scalars after NFC is rejected at pattern compile
with `InvalidPattern` and diagnostic `multi_scalar_member`; silently treating
its decomposition as alternative class members would accept different names.
Composition precedes optional case folding in the shared reading path.

Canonical decomposition is complete, with stable canonical ordering, composition
blocking/exclusions and algorithmic Hangul decomposition and composition.
Malformed UTF-8 bytes remain distinct non-scalar units and segment barriers.
Compatibility decomposition and full case-fold expansion are outside this API.
The iterator retains original byte offsets; outputs reordered within one segment
share that segment's original end, so captures never split a composition.

A fixed 256-class bitset and at most 255 stable scans order each combining
segment. Scratch is constant and work linear in input length with a bounded
Unicode-class factor, even for arbitrarily long combining runs. No truncation,
stream-safe insertion or combining-length limit changes accepted names.
Automata retain their stated bound. NFC disables byte-literal strategies that
could split a scalar; entirely ASCII NFC can use exact hot loops after an ASCII
check. The exact reader remains the default.

Filesystem callers choose equivalence from measured root policy and keep
canonical kernel spelling and identity. Unicode default folding alone does not
establish filesystem identity. This boundary keeps one owner for Unicode data
and one owner for glob grammar without moving filesystem policy into sweep.

## Captures

Captures build a separate tagged program on demand; ordinary matches carry no
capture histories. The caller owns reusable scratch per concurrent query and
keeps its Pattern alive. Ordered Pike execution chooses the first successful
alternative and greedy repetitions. Results are original subject byte offsets;
unselected captures are null, participating empty captures have equal endpoints,
and repeated items retain their last participating iteration. Scratch is
O(states * captures); history copying adds O(captures) per visited state.

## Validation contract

Committed vectors and independent dialect oracles compare matching engines;
git differential cases protect exact defaults. The complete committed Unicode
18 normalization corpus checks canonical equivalence, including exclusions,
Hangul and combining-order cases. Syntax-aware NFC cases check classes, ranges,
negation, escapes, wildcard boundaries, malformed bytes, folding, mixed-policy
Sets, ancestor/capture offsets and long combining runs. Shakedown supplies
seeded generators, allocation-failure checks and I/O faults. Deterministic tests
protect matching bounds, scratch ownership, cleanup and query allocations.
Benchmarks live separately in `bench/`; CI compiles them and never uses elapsed
time as a correctness threshold.

## Safety boundaries

Aegis supplies distinct program positions and original source-byte offsets for
parser frames. Set entry identities (`Set.Index`), entry counts (`Set.Count`) and
cache byte capacity (`Set.Bytes`) are separate domains; typed results cross the
public boundary, while validated dense indices stay raw inside query kernels.
An index belongs to its Set: the tag distinguishes domains, not Set instances
or lifetimes. Caches still borrow their Set and require caller synchronization.

Construction bounds count Nodes, Classes, Ranges and Frames separately.
Arithmetic is checked in all build modes before allocation; source-byte and
group counts convert explicitly into grammar expansion bounds. Conservative
estimates may exceed the packed instruction address space;
accepted patterns retain their meaning. Emission enforces the actual node
limit, and `PatternTooLong` rejects an exhausted combined program.
Combined-bound failure leaves the
previous bound unchanged. A failed Set build still follows its documented entry
consumption contract. Capture-history sizing uses checked multiplication before
allocating its state-by-capture matrices. Accept indices use a ranged integer
before packing the directory bit into the instruction operand.

Retained raw sites carry `aegis:` reasons beside their declarations or kernels.
They fall into three classes in this implementation:

- Measured boundary: parser/builder slice cursors, NFA/DFA/cache states, private
  set/table query indices and capture histories operate on validated programs,
  slices and dense entry order. Inner loops preserve the packed scalar form.
- Safe type internals: a four-byte instruction operand changes meaning with its
  Op; construction validates every domain before the executor reads it. Aegis
  scalar factories accept ABI integer widths, so a 28-bit enum would not fit
  this packed representation. Widening every instruction would change its cost.
- Design or no danger: signed interval endpoints are checked by `parseInt`,
  descending ranges are refused, and decimal magnitude steps remain within the
  signed endpoint magnitude. Capture ordinals are privately issued by the
  bounded compiler. Interned decimal classes and single-entry strategies never
  cross numeric domains. Diagnostics/capture endpoints report only original
  source/subject bytes. Unicode scalars, combining classes and source cursors
  are separate fields bounded by their tables or borrowed slice.

There are no secrets, locks beside shared data, or foreign numeric identities
in the pure matcher. Aegis's currently published API supplies no input marker
or owned compilation container; validation and cleanup remain with sweep's
existing parser and explicit allocating owners. No speculative layer is added.

The package preflight configuration selects Glint A004 as a gate for adopted
identity, unit and integer domains. Its source selection includes tests, benchmarks,
examples and CI drivers. The pinned published preflight predates Glint orchestration,
and published Glint G3 admits aegis reports only; these gate settings await G4
execution. Compiler rejection checks already enforce the public domain distinctions.
