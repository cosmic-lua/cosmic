## Goal
G6 — the defining paths, ratcheted (parent `3HyRcd9F`): `release.yml`'s
release-over-release perf ratchet must not measure a regression against an
honest baseline, watch it survive triage, and then publish it anyway.

## Change

The defect, verified against `origin/main@6a4d0182` (line numbers are that
tree's). `gate_inner` builds `flagged_first` at `_perf/gate.tl:152-157` from
pass 1's deltas, judged against `opts.baseline`. When `opts.measure_baseline`
is set it then re-measures the baseline into `base_side` (`gate.tl:170`) and
judges passes 2 and 3 against THAT file. The strike-twice loop
(`gate.tl:242-249`) compares those two flag sets — so it asks whether the
regression reproduced against a MOVING reference. A scenario whose pass-1
baseline reading was one-off SLOW is masked in pass 1, flags in pass 2 against
the honest retry, survives triage with quiet controls, and is then discarded at
`gate.tl:243` as "flagged only in the retry -- not reproduced".

Reproduced end to end through `gate.gate` on `origin/main`, base
`{a=1000, b=1300}`/`aaaa1111` against current `{a=1300, b=1300}`/`bbbb2222`,
`measure` writing `{a=1000, b=1300}` and `measure_baseline` writing
`{a=1000, b=1000}`:

```
b                                 1.00 µs ->      1.30 µs    +30.0%  (noise  ±10.0%)  regression
perf-compare: regression persists; running A/A self-check to separate real regressions from machine noise
perf-compare: b flagged only in the retry -- not reproduced, counted as noise
b                                 1.00 µs ->      1.30 µs    +30.0%  (noise  ±10.0%)  noise
2 scenarios: 0 regression, 0 faster, 1 ok, 1 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0 malformed
perf-compare: PASS
```

Four files.

**1. `_perf/gate.tl` — re-key the strike-twice rule to the baseline the
failing judgment already uses.** After the baseline retry and its
`identity_refusal(opts.baseline, base_side, true)` check (after `gate.tl:184`)
and before the `identity_refusal(base_side, retry, false)` check at
`gate.tl:189`, add a guarded block: when `base_side ~= opts.baseline`,
recompute `flagged_first` from `compare_once(base_side, opts.current,
opts.threshold)` — the caller's own pass-1 CURRENT file judged against the
RE-MEASURED baseline — replacing the table built at `gate.tl:152-157`. Handle a
negative failure count exactly as the other `compare_once` call sites do
(`io.stderr:write(tostring(err) .. "\n"); return 1`). No new measurement: both
files are already on disk. The rule then reads what it always meant — two
INDEPENDENT current-side samples flagging against ONE common baseline.

The guard is load-bearing: when `opts.measure_baseline` is nil, `base_side ==
opts.baseline`, the block does not run, and behaviour is unchanged for every
invocation without `--baseline-bin`. `--baseline-bin` has exactly one caller:
`git grep -n -- "--baseline-bin" -- .github _perf` on `origin/main` returns
`.github/workflows/release.yml:184` plus `_perf/gate.tl`'s own usage and
argument-parsing lines and nothing else.

Also rewrite the module header comment (`gate.tl:2-13`) to state the rule as it
now is, and to state the sampling asymmetry it does NOT fix: a regression that
reads quiet on the retry ends the gate at `gate.tl:200-202` with two
current-side samples and no A/A control, while one that flags twice gets a
third sample and triage across three control pairs. That asymmetry is captured
as `3IWU4i0l` and is out of scope here.

Measured: `git show origin/main:_perf/gate.tl | wc -l` = 406. The prototyped
change is +23 lines (429) before the header rewrite.

**2. `_perf/gate_test.tl` — split, to make room.** `git show
origin/main:_perf/gate_test.tl | wc -l` = 479, twenty-one lines under the
500-line cap, so the new tests cannot land in it. Move lines 381-479 verbatim —
the blank line, the strike-twice comment block, and the four tests
`test_strike_once_regression_reclassifies_and_passes`,
`test_strike_twice_regression_still_fails`,
`test_baseline_retry_rescues_a_one_off_baseline_reading`,
`test_baseline_retry_naming_a_different_binary_is_refused` — into a new
`_perf/gate_strike_test.tl`. That leaves `_perf/gate_test.tl` at 380 lines with
17 test functions.

**3. `_perf/gate_strike_test.tl` — the new file.** It repeats
`gate_test.tl`'s preamble (lines 1-38: shebang, doc comment, requires,
`write_multi`, `write_results`, `paths`) with its own doc comment naming the
strike-twice rule and the baseline retry, and WITHOUT the `check` and `compare`
requires — the moved tests use neither, and `gate_test.tl` keeps both because
`test_retry_does_not_overwrite_current` still calls `check.must` and
`compare.load_results`. Follow the file's existing shape: `test_*` functions are
defined and not called; the runner extracts them (it reported 21 for
`gate_test.tl`). Add three tests, all in the injected-measure style, all
prototyped and passing:

- `test_masked_baseline_regression_still_fails` — the escape above, asserting
  the gate exits 1. This is the test that FAILS on `origin/main`'s gate.
- `test_a_one_off_fast_baseline_retry_fails_the_gate` — the mirror: base
  `{a=1000, x=1000}`/`aaaa1111`, current `{a=1300, x=1000}`/`bbbb2222`,
  `measure` writing `{a=1000, x=1000}`, `measure_baseline` writing
  `{a=1000, x=700}`. `x` is steady on every current-side run and the baseline
  RETRY is the one-off, so both current samples now flag against it and the gate
  exits 1 where it used to exit 0. This pins the accepted cost of the change,
  and it also fails on `origin/main`'s gate.
- `test_current_side_instability_absorbs_the_fast_baseline_retry` — the same
  numbers except the second `measure` call writes `x = 1300`. The A/A control's
  +30% swing gives TRIAGE_K credit covering the +42.9% flag, so the gate exits 0.
  This is the guard on the cost above, and it passes both before and after.

Measured: with the move and the three tests the file is 212 lines.

**4. `docs/decisions/dNN-<slug>.md`, plus the regenerated index.** This
changes a release gate's sampling rule and gives something up, so it earns a
record under `skills/decide`. Take the next free number by `ls docs/decisions/`
on the branch cut from latest `origin/main`: `d32` is the highest on main today
and `d33` is already claimed by an in-flight branch
(`origin/claude/3IWJ2cHm-metatable-value-type`), so check at branch time and
renumber if that lands first. H1, exactly: `# D<n> — the perf gate judges
reproduction against the re-measured baseline`. Then `bin/cosmic
_docs/derive.tl` to rewrite the index table in `docs/decisions/README.md`.

The record's four sections, decided here:

- **context** — the escape above with its gate output; that `release.yml`
  re-baselines to the previous release's BINARY daily, so one escape is absorbed
  into the ratchet permanently and never re-asked; and the machine evidence that
  a one-off per-scenario reading is routine on either side. That evidence,
  measured 2026-08-28 in one container from a worktree at `origin/main@6a4d0182`:
  `bin/cosmic --make run _perf/gate.tl selfcheck A.json B.json` over the full
  suite reported `48 scenarios: 12 regression, 2 faster, 34 ok, 0 noise, 0 new,
  0 missing, 0 error, 0 baseline-error, 0 malformed` — 14 of 48 scenarios move
  past the 10% bar with the SAME binary measured twice back to back, up to
  +62.2% (`re_split_colon_list`), +57.3% (`sqlite_point_query`), +32.9%
  (`re_match_log_line`).
- **decision** — the reproduction rule reads ONE baseline, the re-measured one,
  and asks two independent current-side samples about it. `TRIAGE_K` and the
  default bar are untouched.
- **rejected**, each with the reason it lost:
  - *keep pass 1's flags as measured.* The losing option a competent
    contributor would pick: requiring the flag against BOTH baseline readings
    suppresses strictly more noise, and a false red is the failure
    `skills/optimize/measurement.md` calls expensive. It loses because the two
    errors are not symmetric in cost — a false red costs one workflow re-run,
    while the false green it produces is absorbed into the next release's
    baseline and can never be re-asked.
  - *count a regression flagging in EITHER pass (the union).* Reinstates the
    false red the strike-twice rule was added to remove — a scenario flagging
    only in the retry from CURRENT-side variance, which
    `test_strike_once_regression_reclassifies_and_passes` pins.
  - *also give the baseline pair its own noise credit.* `opts.baseline` and
    `base_side` measure the same binary by construction (the gate enforces it at
    `gate.tl:179`), so their disagreement is a legitimate A/A control that would
    absorb the mirror false red directly. Correct, and better — rejected here as
    a separate slice, because `_perf/compare.tl`'s `loudest_control` is not
    exported and adding the pair to the existing `controls` list would form
    baseline-vs-current pairs, which is the comparison under test; it needs
    `triage_many` to take a second control GROUP. Rejected as premature, not
    forever: the measured evidence is that a scenario unstable enough to produce
    a one-off baseline reading is normally unstable on the current side too,
    where the existing credit already absorbs it — which is exactly what
    `test_current_side_instability_absorbs_the_fast_baseline_retry` shows.
- **consequences** — names the cost in the false-positive direction (the
  residue: a scenario quiet across all three current-side control pairs whose two
  baseline readings disagree past the bar now fails where it used to pass), the
  remedy `release.yml` already prints for a false red ("re-run the workflow"),
  and what would make us revisit (repeated reds traceable to the baseline retry
  — then buy the baseline-pair credit above).

## Non-goals
- Do not change `TRIAGE_K`, `DEFAULT_THRESHOLD_PCT`, `loudest_control`,
  `triage`, `triage_many` or anything else in `_perf/compare.tl`.
  D31 (`docs/decisions/d31-gate-noise-from-every-control-pair.md`) governs
  how much variance a scenario is credited for and stands unamended; this change
  is only about WHICH baseline the reproduction rule reads.
- Do not add a measurement pass anywhere. The re-key reads two files the gate
  has already written; a fix that costs runs inside `release.yml`'s
  15-minute-timeout step is a different change.
- Do not touch `_perf/gate.tl:200-202`, the quiet-pass-2 early return. State the
  asymmetry in the header comment; the fix is captured as `3IWU4i0l`.
- Do not touch `.github/workflows/release.yml`, `skills/optimize/SKILL.md` or
  `skills/optimize/measurement.md`. PR #1480 (item `3IVF3HbV`) is in flight over
  the first two; the third is its neighbour and not needed for this change.
- Frozen contracts: the `perf-compare: PASS` / `perf-compare: FAIL` verdict
  lines, `compare.format`'s summary line, and the `perf-compare: <name> flagged
  only in the retry -- not reproduced, counted as noise` line — `release.yml`
  tees and greps this output.
- Do not rename, remove or weaken a scenario or its `check()`.
  `_perf/compare.tl` counts a baseline scenario missing from the current run as
  a failure, so a rename blocks every later release.
- Do not hand-edit the table under `| # | decision | status | |` in
  `docs/decisions/README.md`; `_docs/derive.tl` owns those rows.
- Do not commit anything under `o/perf/`.

## Acceptance
Run from the repo root. Every command below was run against the prototyped
change on 2026-08-28 and the verdicts quoted are the ones observed.

- `git diff origin/main...HEAD --name-only` lists exactly five paths:
  `_perf/gate.tl`, `_perf/gate_test.tl`, `_perf/gate_strike_test.tl`,
  `docs/decisions/dNN-<slug>.md`, `docs/decisions/README.md`.
- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`. Observed on the
  prototype: `fmt: PASS (550 files)`, `check: PASS (550 files)`, `example: PASS
  (35 files)`, `lint: PASS (652 files)`, `coverage: PASS (252 files)` with
  `coverage ratchet ok` — the committed floor did NOT need regenerating. If the
  coverage stage does complain, run exactly the command its failure message
  prints and commit the result; do not weaken a gate by any other route.
- `bin/cosmic --make test _perf/gate_test.tl _perf/gate_strike_test.tl` ends
  `test: PASS (2 files)` and reports `24 tests: 24 passed`, split
  `_perf/gate_test.tl (17 test functions)` and `_perf/gate_strike_test.tl (7
  test functions)`. On `origin/main` today the same two files are one file
  reporting `_perf/gate_test.tl (21 test functions)`.
- The two new failing-case tests must FAIL without the fix. This builds
  `origin/main` in a throwaway worktree under `o/` (build output, never
  committed) with only the new test file copied in, and removes it again:

  ```
  rm -rf o/gate-premise && git worktree add --detach o/gate-premise origin/main \
    && cp _perf/gate_strike_test.tl o/gate-premise/_perf/ \
    && mkdir -p o/gate-premise/o \
    && cp -r o/3p o/bootstrap o/bin o/gate-premise/o/ \
    && (cd o/gate-premise && ./bin/cosmic --make test _perf/gate_strike_test.tl); \
    git worktree remove --force o/gate-premise
  ```

  It must end `test: FAIL (1 of 1 file)` with `7 tests: 5 passed, 2 failed`,
  naming `test_masked_baseline_regression_still_fails` (`... must still fail,
  got 0`) and `test_a_one_off_fast_baseline_retry_fails_the_gate` (`... on a
  stable scenario fails, got 0`). A gate fix nothing reproduces is worthless:
  if this ends PASS, the fix is not doing what the spec says.
- `bin/cosmic --make test _build/docs_test.tl` ends `test: PASS (1 file)` after
  `bin/cosmic _docs/derive.tl`, which is the gate that the decision index
  matches the records.
- The 500-line cap, as commands with their bounds — measured on the prototype
  at 429 / 380 / 212, with the header rewrite still to add to the first:
  `wc -l < _perf/gate.tl` ≤ 460, `wc -l < _perf/gate_test.tl` ≤ 400,
  `wc -l < _perf/gate_strike_test.tl` ≤ 260.
- The guard that keeps the change inert without `--baseline-bin`:
  `grep -c "base_side ~= opts.baseline" _perf/gate.tl` = 1 (0 on
  `origin/main`), and `grep -c "flagged_first" _perf/gate.tl` = 5 (3 on
  `origin/main`: `git show origin/main:_perf/gate.tl | grep -c flagged_first`).
- `git grep -n -- "--baseline-bin" -- .github` returns exactly
  `.github/workflows/release.yml:184`, unchanged by this diff.

## Enablement
none needed. The wrong turns a literal-minded session could take are each
caught by something in this slice or already in the tree: recomputing
`flagged_first` unconditionally (and so changing every local gate run) is
caught by the 17 unchanged tests in `_perf/gate_test.tl` and by the
`grep -c "base_side ~= opts.baseline"` bound; putting the new tests into
`_perf/gate_test.tl` and blowing the 500-line cap is caught by
`cosmic --check lint` and by the `wc -l` bounds above; dropping the negative
failure-count propagation is caught by `--check types`, which fails on any
unused value; a decision record with a malformed H1 or a stale index row is
caught by `_docs/derive.tl` and `_build/docs_test.tl`; and a fix that does not
actually close the escape is caught by the premise command. No blocker items.

**Composes with PR #1480** (item `3IVF3HbV`, in `check`), which rewrites
`measure_baseline`'s construction inside `main()` at `_perf/gate.tl:349-380` and
adds `_perf/baserun.tl`. The regions are disjoint from this slice's, which is
inside `gate_inner`. Verified, not assumed: `git merge-tree --write-tree
--messages <this-change> origin/claude/3IVF3HbV-perf-scoped-manifest` exits 0
with `Auto-merging _perf/gate.tl` and no conflict, and the resulting tree
carries both hunks (`base_side ~= opts.baseline` at line 185 and
`require("_perf.baserun")` at line 382). No `blocked_by` edge, and either may
land first. #1480 also edits `.cosmic-coverage`; this slice does not, so the two
cannot collide there.
