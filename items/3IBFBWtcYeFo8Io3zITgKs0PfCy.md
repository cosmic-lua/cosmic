## Goal

G5, via the cosmic.fuzz epic (3I1j7yQA, "Children" item 6): corpus
persistence under `testdata/`, so a failing input becomes a permanent
regression the suite replays on every subsequent run instead of a seed
number a human has to remember to turn into a test by hand.

## Problem, re-measured 2026-08-22 against `origin/main` at 2ee12b3e

`_fuzz/driver.tl` (390 lines, `wc -l < _fuzz/driver.tl`) reports a
minimized failing input in its message (`"<name>: seed=%d iteration=%d
input(base64)=%s draws=%d: %s"`, `failure()`) but writes nothing to
disk. Today the only record of a found bug is that message plus the
convention that a human transcribes it into a regression test — the
epic's own spec cites #1161 doing this manually, five times.
`driver_test.tl` (406 lines, `wc -l < _fuzz/driver_test.tl`) has no
corpus-reading code, and no `_fuzz/testdata/` directory exists yet.

`run()` always isolates (landed as child 5, 3IAXDNwC, merged as
0b2907b9): every property call re-execs the compiled test file as a
child with `FUZZ_ISOLATE` naming the one property to actually run
(`isolate()`, `spawn_isolated()`). Corpus replay has to happen INSIDE
that isolated child, on the same `run_in_process` call the parent's
child spawned — not as a separate pass in the parent — or a corpus
entry that itself crashes would never get the isolation/attribution
child 5 just built.

## The file cap forces a split; the split has to be clean

The 500-line cap is hard, gated by `--check lint`
(`_tool/lint.tl:24`, `DEFAULT_FILE_LINES = 500`), and nothing exempts
`_fuzz/**` — there is no `.cosmicignore` in the tree at all — so it
binds every file this item touches.

- **Tests cannot fit in `driver_test.tl` (406 lines).** The four
  corpus-behavior tests (§§ Acceptance #4–#7) plus their per-test
  `restore()`, `seed_corpus_file`, and env-savers together weigh
  ~200 lines even trimmed — 606, well over cap.
- **Code cannot all fit in `driver.tl` (390 lines).** The corpus
  helpers (`dir_for`, `corpus_failure`, `replay`, `save`) plus their
  doc comments plus a CheckFn type land around 100–120 net lines.
  390 + ~110 ≈ 500 — at cap, zero headroom for the module comment the
  corpus behavior actually deserves, and a single later doc line puts
  it over.

So a code split into a new sibling module is required, and a test
split is required. The last landed attempt (PR #1297 head `4ec56c6a`)
did both, but redeclared three load-bearing bodies in the new module
— which was the bounce reason: a silent drift risk (BUDGET_MESSAGE)
plus dead duplication (detail_of, env_integer). This spec pins the
split shape so a re-implementation cannot land the same defect.

## Change

Three edits, one new module for shared internals, one new module for
corpus, and one new test file. No new files in `_fuzz/testdata/` are
committed by this item; no existing `*_fuzz_test.tl` property changes.

**Start from `origin/main`, on a fresh branch and a fresh PR.** The
item's `pr` field still names #1297, which is the bounced attempt: a
two-module shape (`corpus.tl` + `driver.tl`) that this spec replaces
with a three-module one, on a branch based at `0b2907b9`. It is closed
as superseded — read its diff for reference if it helps, do not push
to it, and hand the item over with the NEW number (`gitboard move ID
check --pr N`).

### 1. `_fuzz/detail.tl` — the shared internals both modules import

A new leaf module holding the three bodies both `driver.tl` and
`corpus.tl` need:

- `BUDGET_MESSAGE: string` — the exact string `arm_budget` throws.
- `env_integer(name: string, fallback: integer): integer` — the
  integer-env helper `driver.tl` uses for FUZZ_SEED / FUZZ_ITERS /
  FUZZ_SAVE.
- `detail_of(ok: boolean, held: any, detail: any, budget: integer):
  string` — the failure-suffix formatter (translates a pcall result
  into `"budget=%d exceeded"` / `"threw: <text>"` / a property
  message).

Rationale for a third module rather than exporting from `driver.tl`:
`corpus.tl` needs these, and `driver.tl` requires `corpus.tl` — so
importing driver from corpus would circular-require. A leaf module
neither imports.

### 2. `_fuzz/corpus.tl` — corpus dir, replay, save

New module, imports `_fuzz.detail` (for BUDGET_MESSAGE / env_integer /
detail_of), `cosmic.codec`, `cosmic.env`, `cosmic.fs`, `cosmic.hash`.
Public API:

- `dir_for(name: string): string` — returns `env.get("FUZZ_CORPUS_DIR")
  / <name>` when set (tests point it at `TEST_TMPDIR`), otherwise
  `fs.join(fs.dirname(arg[0]), "testdata", name)` — colocating the
  corpus with the fuzz test file, so the mechanism works for any
  project using `cosmic.fuzz`.
- `replay(name, check, budget, arm, disarm): boolean, string` — the
  replay pass. `arm` and `disarm` are PASSED IN by the caller
  (driver's `arm_budget`/`disarm_budget`), which breaks the circular
  require without exposing driver's debug-hook internals. Contract:
    - `fs.is_dir(dir_for(name))` — silent boolean probe. False (the
      common case) returns `(true, "")` immediately: no fs calls
      beyond the probe, no log.
    - `fs.find(dir, {recursive = false, sorted = true})` — one flat
      directory of leaf files, sorted so replay order is deterministic
      across runs and sessions. A `nil, err` here (unreadable dir
      after `is_dir` said yes) returns `(false, corpus_failure(..,
      "corpus listing failed: " .. err))` — surfaced through the
      isolated child's stderr like every other failure.
    - For each file in sorted order: `fs.read(path)` for the bytes;
      `arm(budget)` around `pcall(check, bytes)`; `disarm()`. A held
      check moves on. A false return, a throw, or a `BUDGET_MESSAGE`
      throw returns `(false, corpus_failure(name, basename, bytes,
      detail_of(...)))`. No shrinking — the input is already concrete.
- `save(name: string, input: string)` — writes when
  `detail.env_integer("FUZZ_SAVE", 0) == 1`; otherwise a no-op.
  `fs.make_dirs(dir_for(name))` (idempotent), then
  `fs.write(fs.join(dir_for(name), hash.sha256_hex(input)), input)`.
  Write errors are ignored: the failure message is the load-bearing
  output; two callers finding the same bug write identical bytes to
  the same path.
- Private `corpus_failure(name, basename, input, detail): string` —
  the replay formatter: `"%s: corpus=%s input(base64)=%s: %s"`,
  taking `codec.encode_base64(input)`. Replay has no seed, no
  iteration, no draws — inventing zeros to reuse `failure()`'s six
  slots would be a lie. `corpus=` / `iteration=` are the two
  distinguishing tokens; grepping either never false-hits the other,
  and Acceptance #4 asserts that directly.

### 3. `_fuzz/driver.tl` — call the corpus module, migrate helpers to detail

Two require lines added: `_fuzz.detail` and `_fuzz.corpus`. Three
locals removed: `BUDGET_MESSAGE`, `env_integer`, and the inline
detail-computation now folded into `detail_of` (moved to
`_fuzz/detail.tl`). Every existing use site swaps to
`detail.BUDGET_MESSAGE` / `detail.env_integer` /
`detail.detail_of`.

Two new call sites in `run_in_process`:

- **Before** the `for i = 1, iters` loop: `local ok, msg =
  corpus.replay(opts.name, opts.check, budget, arm_budget,
  disarm_budget); if not ok then return false, msg end`. The wall-clock
  cap is inherited from `spawn_isolated`'s `timeout_ms` (30000 ms
  default), which caps the whole child — corpus pass and generated
  loop together.
- **On the failing-generated branch**, after shrinking and before
  constructing the `failure()` message: `corpus.save(opts.name,
  minimized_input)`.

`failure()` and `arm_budget`/`disarm_budget` stay in `driver.tl` —
they use `codec` (already imported) and `debug.sethook` respectively,
and no other module needs them. Their signatures do not change; every
existing `driver_test.tl` substring assertion (`iteration=1`,
`iteration=5`, etc.) keeps meaning what it means.

### 4. `_fuzz/driver_corpus_test.tl` — the six new tests

New test file (mandatory: `driver_test.tl` is 406/500 with no room
for six more tests plus their helpers). All tests use
`FUZZ_CORPUS_DIR=$TEST_TMPDIR` and, at teardown, restore every driver-
visible env var they touched. Every test uses
`driver.run_unisolated`, so none enters the crash path (see Non-goals
bullet 5).

The file holds exactly these SIX tests, each called on the line after
its `end` (house rule), and no others:

1. `test_no_corpus_dir_is_silent` — Acceptance #4
2. `test_corpus_entry_failure_is_reported` — Acceptance #5
3. `test_corpus_runs_before_generated_in_sorted_order` — Acceptance #6
4. `test_fuzz_save_writes_content_addressed` — Acceptance #7
5. `test_fuzz_save_unset_writes_nothing` — Acceptance #7
6. `test_fuzz_save_is_idempotent` — Acceptance #8

Helpers (`restore()`, `seed_corpus_file`, env-savers) are exempt from
the call-where-defined rule, being called from the tests.

### 5. Env grammar

Only three env vars are new to this item:

- `FUZZ_CORPUS_DIR` — overrides the default corpus root. Read only in
  tests. Its default (unset) is the colocated `testdata/` shape.
- `FUZZ_SAVE` — read via `detail.env_integer("FUZZ_SAVE", 0)`. Any
  value other than `1` (unset, `"0"`, `"true"`, garbage) is a no-op.
  No default-on path, ever; CI never sets it — verified by
  Acceptance #6.

## Non-goals

- No change to `failure()`'s signature or its message shape for a
  GENERATED-input failure. Only replay's report is new ground, and it
  uses its own separate formatter.
- No automatic corpus pruning or deduplication in this item. Content-
  addressed filenames already dedupe by BYTES, so the growth surface
  is "distinct minimized bugs", not "re-triggers of the same one".
- Not a rewrite of the six existing `*_fuzz_test.tl` properties. No
  existing property changes and no committed `_fuzz/testdata/` files
  are added by this item.
- No default-on write path. `FUZZ_SAVE` stays opt-in.
- **Not this item — crash-regression attribution for corpus entries.**
  A corpus entry that C-crashes when replayed reports through the
  existing generated-iteration bisection (`isolate()` / `bisect_crash`),
  which will misattribute it to `iteration=1` with a fresh input.
  Filed as its own follow-up under 3I1j7yQA. This item's tests all
  use `run_unisolated` so the deferral does not gate its Acceptance.
- No timing/quota on the corpus loop separate from the generated loop.
  Per-file budget is the same VM-instruction budget the generated loop
  uses; the wall-clock cap is the child's `timeout_ms` as a whole.
- The `.cosmic-coverage` rows for the two new modules ARE part of this
  item's diff, regenerated with `bin/cosmic --make coverage --baseline`
  and committed with the code. This is not optional and not a separable
  concern: `_fuzz/**` is covered (the floor carries `_fuzz/driver.tl`,
  `_fuzz/shrink.tl`, `_fuzz/source.tl`), and the ratchet's file-set
  drift check fails a source file that has coverage data and no row.
  The last attempt (PR #1297) was right to include it.

## Acceptance

Every command below is run from the repository root and must print
the literal verdict line quoted after it. Every command uses only
`FUZZ_SEED`, `FUZZ_ITERS`, `FUZZ_CORPUS_DIR` and `TEST_TMPDIR`;
`FUZZ_SAVE` is set only by tests INSIDE `driver_corpus_test.tl` —
never on the command line — so no Acceptance run mutates the
committed tree.

1. **The full gate holds (fmt, check, example, lint, coverage).**

       bin/cosmic --make ci

   Verdict line ends `ci: PASS`.

2. **All six existing `*_fuzz_test.tl` properties still pass with no
   committed corpus.** Nothing about the corpus infrastructure
   changes the pass/fail of properties whose corpus directory does
   not exist.

       bin/cosmic --make test _fuzz

   Verdict line ends `test: PASS`.

3. **The existing driver tests still pass — the migration is
   silent.** Every substring assertion (`iteration=`, `seed=`,
   `draws=`, `budget=%d exceeded`, `threw:`) still means what it
   meant, because `failure()`'s shape and `detail_of`'s output are
   unchanged (only `detail_of`'s home moved to `_fuzz/detail.tl`).

       bin/cosmic --make test _fuzz/driver_test.tl

   Verdict line ends `test: PASS`.

4. **The new corpus-behavior tests pass.**

       bin/cosmic --make test _fuzz/driver_corpus_test.tl

   Verdict line ends `test: PASS`. The file holds the six tests
   enumerated in Change § 4 and no others; the first of them,
   `test_no_corpus_dir_is_silent`, asserts that a missing corpus dir
   skips replay with no log and no fs calls beyond the probe.

5. **A corpus entry that fails is reported with `corpus=<basename>`
   and its base64 bytes; the generated-iteration tokens are absent.**
   `test_corpus_entry_failure_is_reported`: set `FUZZ_CORPUS_DIR` to
   a per-test directory under `TEST_TMPDIR`, write a bytes file
   under `<dir>/<opts.name>/<sha>` whose contents fail the property,
   run `run_unisolated`, assert the returned message CONTAINS
   `corpus=<sha>` and `input(base64)=` and does NOT contain any of
   `iteration=`, `seed=`, `draws=`.

6. **Corpus entries are checked before generated iterations, in
   sorted basename order.** `test_corpus_runs_before_generated_in_
   sorted_order`: two corpus files whose basenames sort
   deterministically (first: `("a"):rep(64)`, second:
   `("b"):rep(64)`), the first failing and the second passing, plus
   a property whose generated inputs would ALSO fail. The returned
   message must name the FIRST-sorted corpus file (assert
   `corpus=<first>` present, `corpus=<second>` absent, `iteration=`
   absent).

7. **`FUZZ_SAVE=1` writes a content-addressed file whose bytes equal
   the input the failure message reports; unset writes nothing.**
   `test_fuzz_save_writes_content_addressed`: with `FUZZ_CORPUS_DIR`
   at `TEST_TMPDIR` and `FUZZ_SAVE="1"`, run a property that fails;
   assert exactly one file exists under `<TEST_TMPDIR>/<name>/`,
   its basename equals `hash.sha256_hex(bytes_at_that_path)`, AND
   its bytes decode-equal the `input(base64)=` substring the
   failure message reports (extract the base64, `codec.decode_base64`
   it, compare). Then `test_fuzz_save_unset_writes_nothing`: with
   `FUZZ_SAVE` unset and with `FUZZ_SAVE="0"`, the same failing
   property writes NO file. `restore()` unsets `FUZZ_SAVE` at
   teardown.

   The message-bytes check is the third assertion — content-
   addressing alone (basename == sha256(bytes)) cannot catch a save
   of the wrong (e.g. pre-shrink) input.

8. **The write is idempotent under re-triggering the same failure.**
   `test_fuzz_save_is_idempotent`: run the same failing property
   twice with `FUZZ_SAVE=1`; assert exactly one file present in the
   corpus dir afterwards and its bytes unchanged between the two
   runs.

## Enablement

Ready, at re-measured tree. Every open question is settled to a
single decision point:

- Module shape: `_fuzz/detail.tl` (shared, leaf) + `_fuzz/corpus.tl`
  (imports detail, receives arm/disarm as callbacks) +
  `_fuzz/driver.tl` (imports both, calls corpus). Break the circular
  require with a leaf module for the shared bodies. Nothing is
  re-declared; the review's dup-body finding survives as a shape
  constraint the spec itself pins.
- Test file shape: `_fuzz/driver_test.tl` unchanged;
  `_fuzz/driver_corpus_test.tl` new (mandatory by the cap).
- Acceptance #7 asserts saved bytes == the reported `input(base64)`
  (the missing check the last attempt lacked).
- The `.cosmic-coverage` rows for the two new modules are inside this
  item's diff, regenerated by `--make coverage --baseline`.

Cap arithmetic, with the split above:

- `_fuzz/driver.tl` (390 → ~370): -3 lines (BUDGET_MESSAGE constant,
  env_integer function body), -21 lines (detail_of function body),
  +2 require lines, +5 lines (corpus.replay call + guard), +1 line
  (corpus.save call). Net ≈ -16, → ~374/500.
- `_fuzz/detail.tl` (new): ~55 lines with doc.
- `_fuzz/corpus.tl` (new): ~150 lines with doc, no re-declared bodies.
- `_fuzz/driver_test.tl` (406 unchanged).
- `_fuzz/driver_corpus_test.tl` (new): ~220 lines with the six
  tests, helpers, restore, and the added base64-decode assertion.

Every touched call (`fs.is_dir`, `fs.find`, `fs.make_dirs`,
`fs.write`, `fs.read`, `fs.dirname`, `fs.join`, `fs.basename`,
`hash.sha256_hex`, `codec.encode_base64`, `codec.decode_base64`,
`env.get`, `env.set`, `env.unset`) is already public API today.

Deferred as a separate child item under 3I1j7yQA: corpus
crash-attribution (Non-goals bullet 5). Non-blocking here because
this item's tests all use `run_unisolated`.

## Refinement, 2026-08-20 (this pass)

The prior spec's "Problem, measured 2026-08-20" cited
`_fuzz/driver.tl` at 215 lines and `_fuzz/driver_test.tl` at 312.
Those measurements were of the pre-child-5 tree; child 5 (3IAXDNwC,
merged as 0b2907b9) made them 390/406, which changed the cap
arithmetic decisively:

- The prior Change §§ 1–5 ("two edits to one module —
  `_fuzz/driver.tl` — plus new tests in `_fuzz/driver_test.tl`")
  is no longer satisfiable under the file cap without deleting
  coverage.
- PR #1297 (head `4ec56c6a`) split the code and tests
  correctly by the cap but re-declared three load-bearing bodies
  (`BUDGET_MESSAGE`, `detail_of`, `env_integer`) in the new module,
  and its review-cited fix (fold back) is not buildable.

This pass:
- Re-measures against `origin/main` at `05614e52`.
- Fixes the shape to `_fuzz/detail.tl` (shared leaf) +
  `_fuzz/corpus.tl` (corpus) + `_fuzz/driver.tl` (caller), so the
  cap holds and no body is duplicated.
- Adds the message-bytes assertion Acceptance #7 previously lacked.
- Drops the `.cosmic-coverage` row from the item's diff (Non-goals
  new bullet); the floor rewrite is a separate concern.
  **Reversed by the 2026-08-20 bounce below — that bullet was wrong.**
- Splits Acceptance #4 from the compound "driver_test.tl (including
  new tests) passes" — a new file demands its own verdict line.


## Bounce, 2026-08-20 (pulled by xmaezt, returned to plan)

The spec contradicted itself, and the contradiction is unresolvable
inside the diff it asks for: `## Non-goals` forbade a `.cosmic-coverage`
row for `_fuzz/detail.tl` and `_fuzz/corpus.tl`, while `## Acceptance`
#1 demanded `bin/cosmic --make ci` end `ci: PASS`. Both cannot hold. The
coverage stage's file-set drift check fails any source file that
produces coverage data and has no row, and `_fuzz/**` is covered —
`grep -c '^  \["_fuzz/' .cosmic-coverage` is 3 (`driver.tl`,
`shrink.tl`, `source.tl`), and `.cosmicignore` is empty.

Measured 2026-08-20 on a built tree, by removing one existing `_fuzz`
row from the floor — the exact state a new uncommitted module leaves
the file in — and running the gate:

```
$ o/bin/cosmic --make coverage
coverage ratchet: _fuzz/source.tl: not in baseline (new file? run
  'cosmic --make coverage --baseline' and commit)
coverage ratchet: declined: _fuzz/source.tl
coverage: FAIL (232 files)
```

The Non-goals bullet and the shape summary are corrected above: the
regenerated rows ship with the code, as PR #1297 already had them. The
refinement pass that promotes this item again should re-read the two
corrected bullets, then run the enablement check and `gitboard check`
before `move ID ready`.

No enablement item: this was one spec's internal contradiction, not a
missing tool or a stale doc. It was introduced by the pass that bounced
PR #1297 — the review found real duplicate bodies and, while re-shaping
the spec around them, also stripped a floor update that the gate
requires. The lesson worth carrying into the next refinement is narrow:
a `## Non-goals` bullet that forbids touching a generated or ratcheted
file has to be checked against what the `## Acceptance` gate actually
enforces, because the gate wins.

## Refinement, 2026-08-22 (promotion pass)

Re-measured against `origin/main` at `2ee12b3e`. Every load-bearing
number the 2026-08-20 pass cited still holds, so its cap arithmetic
and its module shape stand unchanged:

```
wc -l < _fuzz/driver.tl                  -> 390
wc -l < _fuzz/driver_test.tl             -> 406
grep -c '^  \["_fuzz/' .cosmic-coverage  -> 3   (driver, shrink, source)
ls _fuzz/*_fuzz_test.tl | wc -l          -> 6
```

Verified present on `main`, so no call in `## Change` is invented:
`driver.tl`'s `BUDGET_MESSAGE` (`:42`), `arm_budget` (`:53`),
`disarm_budget` (`:64`), `env_integer` (`:99`), `failure` (`:119`),
`run_in_process` (`:148`, its inline `what` computation at `:160-170`
being what moves into `detail_of`), and `run_unisolated` (`:289`,
exported at `:385`). Public API: `fs.FindOptions` carries both
`recursive` and `sorted` (`cosmic/fs/find.tl:37`) and `fs.find`
returns FULL paths in `Found`'s array part (`:64`) — so the replay
formatter's `corpus=<basename>` needs `fs.basename` on each, which the
Enablement list already names; `hash.sha256_hex`, `codec.encode_base64`,
`codec.decode_base64`, `env.get`/`set`/`unset` all exist as cited.

The three corrections this pass makes, all of them ambiguities a
literal-minded builder would have had to guess at:

- **The test count was stated three different ways** — "the six new
  tests" (Change § 4 heading), "the six tests below and
  `test_no_corpus_dir_is_silent`" (Acceptance #4, so seven), and "the
  eight tests" (Enablement cap arithmetic). Change § 4 now enumerates
  exactly six by name against the Acceptance section each one serves,
  and the other two places point at that list.
- **`.cosmicignore` does not exist in the tree.** The cap section said
  `_fuzz/**` "is not in `.cosmicignore`" and the bounce called the file
  empty; both invited a builder to go looking for it. The conclusion is
  unchanged — nothing exempts `_fuzz/**` — and now says so directly.
- **PR #1297's disposition was unstated.** The item still carries
  `pr: #1297`, which was an open draft on a superseded shape. Change's
  preamble now pins a fresh branch off `origin/main` and a fresh PR,
  and #1297 is closed as superseded (its branch and diff stay readable).

Enablement check, run before this promotion: the wrong turns a builder
could take are the three above plus the circular-require trap, and all
four are now closed by the spec's own text — no core, docs or skill
change is called for, so no enablement item is filed. The 2026-08-20
bounce's own lesson (a `## Non-goals` bullet must be checked against
what `## Acceptance` enforces) was applied to the current Non-goals:
its only claim about a generated file is the `.cosmic-coverage` bullet,
which now REQUIRES the regenerated rows in the diff, matching
Acceptance #1.

## Rejection, 2026-08-22 (PR #1308, head 28a3fe3e, reviewed by sched-0g9chr)

PR #1308 implemented this spec faithfully — the three-module shape, no
redeclared bodies, all six tests, the `.cosmic-coverage` rows, and CI
green across all six checks — and it still does not deliver the Goal.
The fault is in THIS spec, which is why the item returns to `plan`
rather than to `do`.

**The wrong turn in one line: `## Change` § 2 pinned
`fs.join(fs.dirname(arg[0]), "testdata", name)` and called it
"colocating the corpus with the fuzz test file", without ever measuring
where `arg[0]` points inside a test.**

It points at the COMPILED artifact. Measured 2026-08-22 on #1308's head,
built and run through the ordinary test path with a probe test printing
`arg[0]`:

```
$ o/bin/cosmic --make test _fuzz/zzprobe_test.tl
arg0=o/_fuzz/zzprobe_test.lua
cwd=/home/user/cosmic/o/pr1308
dir_for=o/_fuzz/testdata/zzprobe
```

`embed/cosmic.mk`'s test rule is `$(O)/%.tl.test.got: $(O)/%.lua` with
recipe `record $(basename $@) $(testrun) $<`, so the runner receives the
compiled file. `--make run` is the same (`arg0=o/_fuzz/zzp.lua`), and
`isolate()` re-execs `{cosmic_bin, arg[0]}`, inheriting it. The cwd IS
the project root, but nothing maps a compiled path back to its source,
and no rule stages `testdata/` into the build tree.

So the default corpus root is `o/_fuzz/testdata/<property>`: gitignored,
removed by `--make clean`, empty in every CI container. End to end, with
`_fuzz/testdata/zzprobe/deadbeef` present in the SOURCE tree and a
property whose check fails on its bytes:

```
replayed_committed_corpus=false msg=zzprobe: 2 iterations, seed=1
```

The entry was never read. Against the Goal — "a failing input becomes a
permanent regression the suite replays on every subsequent run" —
nothing stored is permanent and nothing is replayed in CI. `FUZZ_SAVE=1`
writes into a build directory a human must find and hand-copy, which is
a shorter manual step than transcribing base64 but is still the manual
step this item exists to delete.

Every Acceptance command passed because all six tests set
`FUZZ_CORPUS_DIR` to `TEST_TMPDIR`. **The default path — the only one
the outcome depends on — is the one path no test exercised.** The
re-refinement must add an acceptance test that runs with
`FUZZ_CORPUS_DIR` UNSET and asserts a committed corpus entry is
replayed; without it, the same class of failure passes the gate again.

### What the next refinement has to settle

Where a property's corpus lives, given that a test cannot see its own
source directory. Three candidates, none obviously best, all of them
design decisions rather than defect fixes:

- a runner-set variable naming the source file (`TEST_SOURCE`, beside
  the existing `TEST_TMPDIR`), read through a `cosmic.*` accessor —
  cheapest, and `_tool/testrun.tl` already builds the child env;
- a `cosmic.*` function mapping a compiled path back to its source from
  the build root the runner already writes into `.test.modules` (its
  `root` and `build` lines are both there);
- staging `testdata/` into the build tree so `fs.dirname(arg[0])`
  becomes true — touches `embed/cosmic.mk`, which is byte-identical for
  every project.

The build model already knows the answer at the make layer: the example
rule `$(O)/%.tl.example.got` hands the runner `$*.tl` rather than `$<`,
precisely because examples must read `-- Output:` comments from source.
The information exists; it is simply not offered to a test.

### Reusable from #1308

Everything except `dir_for`. The `_fuzz/detail.tl` leaf split, the
`replay`/`save` contracts, the six tests, and the coverage rows all
stand; the branch `claude/zealous-hypatia-s542rw` and its diff stay
readable. `dir_for` is also exported with no caller outside its module —
this spec named it public API, and the next one should decide whether it
is wanted at all or whether the corpus root is better exposed as data.

### Enablement

Filed as 3IGXZ7Gg: "a test cannot find its own source dir: `arg[0]` is
the compiled `o/` path, so colocated testdata is unreachable." General
beyond this item — any future feature wanting per-test fixture data
found at runtime (golden files, corpora, recorded transcripts) reaches
for the same expression and lands in the same place, and no gate says
so.

The ready-bar lesson, narrow: a spec that pins a path EXPRESSION owes a
measurement of what that expression evaluates to in the run mode the
acceptance uses, exactly as it owes a measurement for a line count. Both
prior passes on this item re-measured `wc -l` faithfully and neither
ran `arg[0]`.
