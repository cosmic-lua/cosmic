## Goal
G1 (via G7 — the agent-eval instrument) — "no silent bugs, documented
behavior is verified behavior," applied to the build's own gates: a
`*_test.tl` that reaches the filesystem for its inputs but declares no
`--- reads:` must be caught by a gate, not by a person noticing a green
CI on a tree it did not read.

## Change
Add a new pure lint rule, `reads-declaration`, that flags an
undeclared `fs.glob()` call in a `*_test.tl` file, and wire it into the
existing lint composition — no new CLI surface, no new verb.

1. **New file `_cli/reads_lint.tl`** (mirrors the existing
   `_cli/pattern_args.tl` / `_cli/returns.tl` / `_cli/visibility.tl`
   shape: a small module hosting one family of checks, required into
   `_cli/lint.tl`'s composition). It requires `_make.imports` (for
   `reads_scan`, already public) and the `Diagnostic` type from
   `_tool.lint`, and exports:

   ```
   check_reads_declaration: function(file: string, content: string,
     lines: {string}): {Diagnostic}
   ```

   Logic:
   - Return `{}` unless `file:match("_test%.tl$")`.
   - Return `{}` if `file` is in a local `ALLOWLIST` table (see below).
   - Return `{}` if `#imports.reads_scan(content) > 0` (the file
     already declares at least one read).
   - Otherwise, for every line matching the pattern `fs%.glob%s*%(`,
     append a `Diagnostic` with `rule = "reads-declaration"` and a
     message naming the mechanism and the fix, e.g.: `"%s:%d: fs.glob()
     enumerates files with no '--- reads:' declaration; a static import
     scan can't see what it finds at runtime, so this test's cached
     PASS never re-runs when those files change — add '--- reads:
     <dir>' naming what the glob covers (see _make/imports.tl)."`
   - `ALLOWLIST` starts with exactly one entry —
     `["cosmic/fs/glob_test.tl"] = true` — commented the same way
     `COSMO_REQUIRE_ALLOWLIST` in `_cli/lint.tl` comments its entries
     (this file tests `fs.glob()` itself against a `TEST_TMPDIR`
     fixture; nothing in it depends on the project tree).

2. **New file `_cli/reads_lint_test.tl`** (mirrors
   `_cli/returns_test.tl`'s standalone-test-file shape). Test cases,
   each a `test_*` function called immediately after its own
   definition per AGENTS.md:
   - a `*_test.tl` fixture string containing `fs.glob(DIR, "*.tl")` and
     no `--- reads:` header → one diagnostic, `rule ==
     "reads-declaration"`.
   - the same fixture with a `--- reads: some/dir` header line → zero
     diagnostics.
   - the same fixture named `cosmic/fs/glob_test.tl` (the allowlisted
     path) and no header → zero diagnostics.
   - a non-`_test.tl` file (e.g. `cosmic/fs/find.tl`) containing
     `fs.glob(` → zero diagnostics (scope is test files only).
   - a `_test.tl` fixture calling `fs.find(...)` (not `fs.glob`), no
     header → zero diagnostics (this slice's trigger is `fs.glob`
     only — see Non-goals).

3. **Wire into `_cli/lint.tl`** (current length 448/500 lines;
   headroom 52 — this adds roughly 6 lines, well inside it):
   - add `local reads_lint = require("_cli.reads_lint")` beside the
     other check-module requires (`pattern_args`, `returns`,
     `style`, `visibility`).
   - inside `lint_file`'s `if path:match("%.tl$") then` block, add a
     loop over `reads_lint.check_reads_declaration(path, content,
     lines)` appending into `diagnostics`, alongside the existing
     `check_find_needle` / `check_nil_declaration` / etc. loops.
   - add `check_reads_declaration: function(file: string, content:
     string, lines: {string}): {Diagnostic}` to the `LintModule`
     record and `check_reads_declaration = reads_lint.check_reads_declaration`
     to the `M` table, matching how `check_fallible_returns` (from
     `_cli/returns.tl`) and `check_shard_require`-equivalent entries
     are already re-exported through `_cli.lint`.

4. **`_perf/perf_test.tl`'s header needs NO code change** — the
   one-file fix the finding asked for (`--- reads: _perf/bench` on line
   1) already landed in commit `6831dcc7` ("fix: replace 51 from-any
   casts in _perf/bench with is guards", the exact PR the finding's
   Evidence section describes) and is present in the tree today. This
   slice's job is purely to make that fix load-bearing: prove via
   Acceptance that removing it now fails the new lint, where today it
   does not fail anything.

```facts
$ wc -l < _perf/perf_test.tl
75
$ grep -c '^--- reads:' _perf/perf_test.tl
1
$ head -1 _perf/perf_test.tl
--- reads: _perf/bench
$ wc -l < _cli/lint.tl
448
$ wc -l < _cli/lint_test.tl
436
$ grep -rl 'fs\.glob(' --include='*_test.tl' . | grep -v '/o/'
./cosmic/fs/glob_test.tl
./_perf/perf_test.tl
$ grep -c '^--- reads:' cosmic/fs/glob_test.tl
0
$ grep -n 'rule = "' _cli/lint.tl _cli/pattern_args.tl _cli/returns.tl _cli/visibility.tl _tool/lint.tl | wc -l
9
$ o/bin/cosmic --check lint _perf/perf_test.tl
Style check passed: _perf/perf_test.tl
$ sed '1d' _perf/perf_test.tl > /tmp/perf_test_no_header_test.tl && o/bin/cosmic --check lint /tmp/perf_test_no_header_test.tl
Style check passed: /tmp/perf_test_no_header_test.tl
```
The last two commands are the regression baseline: TODAY, with the
header removed, `--check lint` still reports a clean pass — proving the
current lint has no rule that would catch the exact bug this item is
about. After this slice lands, the same "strip the header, lint the
file" sequence must fail (see Acceptance).

## Non-goals
- **`fs.find` / `fs.find_iter` / `fs.find_info` / `fs.visit` are not
  in scope.** The finding's proposed trigger names `fs.glob`, `fs.walk`
  and `fs.ls` as illustrative examples; `fs.walk` and `fs.ls` do not
  exist in the `cosmic.fs` API (the real names are `fs.glob`, `fs.find`,
  `fs.find_iter`, `fs.find_info`, `fs.visit`). Measured just now: 16
  `*_test.tl` files call one of `fs.find`/`fs.find_iter`/`fs.find_info`/
  `fs.visit` with no `--- reads:` declaration, and all but one or two
  of them enumerate a fixture directory the test itself constructs
  (`TEST_TMPDIR`, a `temp_dir()`/`temp_file()` result) rather than the
  project tree — flagging all of them would be false-positive noise on
  a scale this slice has not audited file-by-file. Only `fs.glob` was
  audited (2 callers total, both handled: one allowlisted, one already
  declares). Widening the trigger to the other four primitives is
  follow-up work, one primitive at a time, each needing the same
  false-positive audit this slice did for `fs.glob`.
- **The "computed `require`" leg of the finding's proposed trigger is
  out of scope.** A syntactic scan for `require` calls whose target
  isn't a string literal was measured against every `*_test.tl` file:
  87 non-literal `require` occurrences across 40+ files, the large
  majority prose mentions or deliberate tests of the require machinery
  itself (`cosmic/searcher_test.tl`, `cosmic/searcher_tree_test.tl`,
  `cosmic/tl_loader_test.tl`) rather than instances of this bug class.
  Getting that trigger's precision right needs its own false-positive
  audit and its own allowlist design — a second, independent detection
  strategy, not a one-line addition to this slice.
- **`_make/pin_test.tl` is a separate, already-measured instance of
  this same bug class** (`fs.find("_make", {glob = "*.tl"})`, no
  `--- reads:`) and **`_eval/stage_test.tl` and `_make/fixpoint_test.tl`
  enumerate non-fixture directories via `fs.find`/`fs.visit`** with no
  declaration either. None of these call `fs.glob`, so this slice's
  lint does not touch them and they are not part of its Acceptance.
  File them as separate findings if not already tracked — do not fix
  them here.
- **No change to `#1178` or `#1156`'s work.** Both are landed (see
  Enablement) — this slice does not touch `_make/imports.tl`'s grammar
  or the D18 env-stamp mechanism, only adds a lint rule that reads
  `reads_scan`'s existing output.
- **No dynamic/runtime inference of reads** (the finding's "stronger,
  much more machinery" alternative: tracing what a test process
  actually `open()`s at runtime and diffing that against its
  declaration). Rejected for this slice: it needs a new collection
  mechanism (an strace-like or fd-tracing harness across every test
  process, cross-platform under Cosmopolitan), a place to store and
  compare the trace, and a decision about what a false-negative trace
  (a path opened only on one branch) means for the gate — three
  open designs where the syntactic rule has zero. It is strictly
  stronger (would also catch `fs.find`/`fs.visit`/computed-require
  cases with no per-primitive audit) and worth a dedicated enablement
  item once the syntactic rule's false-positive experience says the
  cheap version isn't enough; it is not this slice.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/reads_lint_test.tl` ends `test: PASS`,
  covering all five cases in Change item 2.
- `bin/cosmic --check lint _perf/perf_test.tl` prints `Style check
  passed: _perf/perf_test.tl` (the tree's current, correct state stays
  clean — the new rule adds no new failures anywhere in the tree).
- Regression proof, run after the lint change lands, with
  `_perf/perf_test.tl` itself left untouched in the tree:
  ```
  sed '1d' _perf/perf_test.tl > /tmp/perf_test_no_header_test.tl
  bin/cosmic --check lint /tmp/perf_test_no_header_test.tl
  ```
  must exit non-zero and print a `reads-declaration` diagnostic naming
  the `fs.glob(` line — proving that without the header fix already in
  the tree, the new lint is what would have caught #1227's live
  incident (52s cached-PASS CI run over 51 rewritten cast sites in 16
  bench modules).

## Enablement
none needed. `#1178` (multi-token `--- reads:`/`--- env:` grammar) and
`#1156` (D18 env-stamp dependency tracking) are both already landed —
`#1156` via commit `a3cd3189` (PR #1185, "make: declared env values
join a test's deps as a hashed stamp (D18)"), `#1178` via commit
`b66f8874` (PR #1241, "make: reads: declarations are multi-token,
matching env:"). `#1178`'s board item (`3HzAF67MXXCGSPb1OIfYrDCHpGD`)
shows `resolution: completed`, `verdict: accept`; no open board item
exists for `#1156` (no `Imported from whilp/cosmic#1156` item is on
the board, and every reference to it in other items' text — e.g.
`3HyEla9Ld3pHajEG8TUgM6XbRCt`'s "#1156 landed (a3cd318, PR #1185,
closed 2026-08-17)" — describes it in the past tense). This slice
depends only on `imports.reads_scan`, which both landed changes
already shaped; no `blocked_by` edge is needed.
