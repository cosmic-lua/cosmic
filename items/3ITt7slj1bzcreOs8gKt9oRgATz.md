## Goal

G6 — the defining paths, ratcheted: the release perf gate fails only
on regressions that REPRODUCE, so the lane stops being a per-run coin
flip while keeping its teeth. Chosen by the owner (option B,
2026-08-27) over publishing past the gate: fix the statistics first,
then release normally.

## Evidence

Measured 2026-08-27 from release run 33034667243's two attempts (both
FAIL, build-job logs 98394677737 and its attempt-1 sibling) and the
gate source at main `6b88a0db`.

- **Zero cross-attempt reproduction.** Attempt 1's final verdict
  flagged `http_stream_read_1mb` +16.7% (bar ±16.5%); attempt 2
  measured it -3.2% and -4.8%, ok. Attempt 2's final verdict flagged
  `embed_extract_tree` +25.7% (±15.9%) and `json_decode_large` +11.6%
  (±10.0%); attempt 1 had both ok (+0.3%, +5.5%). Inside attempt 2,
  pass 1 flagged only `fs_barf_slurp_64k` +54.6% (±32.5%), which the
  retry read at +0.8%.
- **Failure mode A: the code does not implement its stated intent.**
  `_perf/gate.tl:4-5` says "noise must strike twice in the same
  direction", but `gate_inner` (`:117-196`) never intersects the two
  passes: pass 1 is `diff(base, current)`; on any failure the retry
  measures and pass 2 re-judges `diff(base, retry)` FROM SCRATCH, so
  a scenario clean in pass 1 that flags only in the retry still fails.
  Attempt 2 is the proof: pass-1 flags {fs_barf_slurp_64k} and
  final flags {embed_extract_tree, json_decode_large} are DISJOINT,
  yet the gate failed. An intersection rule passes that run.
- **Failure mode B: the baseline is measured once and anchors both
  passes.** `release.yml:166-177` measures the previous release's
  binary exactly once (`o/perf/prev/cosmic-lua _perf/run.tl --out
  o/perf/prev/perf.json`); the retry re-measures only the CURRENT
  side (`gate.tl:134`). Attempt 1's `http_stream_read_1mb` flag came
  from a baseline reading of 1.65 ms; the SAME binary read 2.00 ms in
  attempt 2 — a one-off low baseline reading that no amount of
  current-side retrying can wash out, which is why that flag "struck
  twice" within attempt 1. An intersection alone does not fix this;
  re-measuring the baseline on retry does.
- **The mechanism is testable by construction.** `gate.tl` injects
  `measure: function(out): integer` and `gate_test.tl` (396 lines,
  17 tests, fabricated results files) exercises every path; the
  retry/triage flow, identity refusals and control harvesting are all
  pinned there. `compare.tl`'s `diff` returns per-scenario `Delta`s
  with `verdict` fields; `triage_many` reclassifies control-explained
  regressions to `"noise"` (a non-failing verdict already in the
  summary format).
- **Headroom.** `wc -l _perf/gate.tl` → 319; `_perf/gate_test.tl` →
  396 (104 under the cap — the new tests must stay inside it, and the
  count below fits); `_perf/compare.tl` → 357. `release.yml`'s gate
  invocation is `:174-176`, one line to extend.
- **Frozen shapes that bound the design.** The verdict line
  `perf-compare: PASS|FAIL`; the summary-line format and its verdict
  vocabulary (reusing `"noise"` avoids changing it); scenarios and
  their `check()`s untouched; `DEFAULT_THRESHOLD_PCT` and `TRIAGE_K`
  unchanged.

## Change

Three files: the gate, its tests, and the workflow's one invocation
line. The decision, in one sentence: **a flagged regression fails the
gate only when it strikes in BOTH passes, and the retry re-measures
BOTH binaries so a single unlucky reading on either side cannot
anchor the verdict.**

### `_perf/gate.tl`

1. `compare_once` also returns its `{pt.Delta}` list (third return —
   slot 1 is `integer`, not nil-admitting, so the fallible-returns
   rule does not bind).
2. `GateOptions` gains `measure_baseline: Measure` (optional field —
   nil when the caller cannot re-run the baseline binary).
3. `gate_inner`, after pass 1 (`diff(base, current)`) flags failures:
   - record `R1 = {name | verdict == "regression"}` from pass 1;
   - measure the current retry as today; when `measure_baseline` is
     set, also measure the baseline retry into
     `retry_path(opts.baseline)` and use THAT as the base side of
     pass 2 and of the final triage — with two identity checks: the
     baseline retry names the SAME binary as the baseline
     (`identity_refusal(base, base_retry, true)`), and pass 2's pair
     still names DIFFERENT binaries;
   - pass 2 and the final triaged pass proceed as today (early return
     0 when the retry compare is clean; controls harvested as today —
     controls are current-binary runs and are unaffected by the
     baseline side);
   - at the FINAL judgment, any delta with `verdict == "regression"`
     whose name is NOT in `R1` reclassifies to `"noise"` with the
     failure count decremented, BEFORE the table is printed — the
     printed table is the record and must show the verdict the gate
     acted on. Print one line naming each strike-once reclassification
     (`perf-compare: <name> flagged only in the retry — not
     reproduced, counted as noise`). `error`/`missing`/
     `baseline-error`/`malformed` verdicts never reclassify.
   - Update the module doc comment: the header's "noise must strike
     twice" sentence now describes what the code does, and says the
     baseline retry exists because a single baseline reading
     otherwise anchors every pass.
4. `main`: accept `--baseline-bin PATH` in the option loop; when
   given, build `measure_baseline` as: run `PATH _perf/run.tl --out
   OUT <runargs...>` via `cosmic.child.run`, returning the exit code
   — the EXACT invocation shape `release.yml:173` uses for the
   baseline measure, so script-mode module resolution is identical.
   Update the usage text.

### `_perf/gate_test.tl`

Four tests, in the file's fabricated-results style (multi-scenario
results files where needed — `write_results` may need a variant
taking a list; keep the file under 500 lines):

- strike-once reclassifies: pass 1 flags scenario A only, the retry
  is clean for A but flags scenario B → gate PASSES, B's final
  verdict is noise;
- strike-twice still fails: the same scenario flags in pass 1 and in
  the final triaged pass → gate FAILS (the regression-detection tooth
  is intact — this is the regression test for the gate itself);
- the baseline retry is used when `measure_baseline` is set: a bad
  one-off baseline reading (base file slow-biased) with a clean
  baseline retry → gate PASSES, and the baseline retry file exists at
  `retry_path(baseline)`;
- a baseline retry naming a DIFFERENT binary than the baseline is
  refused (identity guard).

Existing seventeen tests pass unchanged except where a signature
ripples (`compare_once` is local — no test calls it; `GateOptions`
gains an optional field — existing literals stay valid).

### `.github/workflows/release.yml`

The gate invocation (`:174-176`) gains `--baseline-bin
o/perf/prev/cosmic-lua`. Nothing else in the workflow moves; the
`perf_gate: false` escape and all step comments stand. NOTE: pushing
a `.github/workflows/**` change may be refused if the credential
lacks the `workflows` permission — if the push is rejected for that
reason, land the gate+tests without the workflow line, and file the
one-line workflow edit as its own item for a human push; the gate
change is compatible with the flag absent.

## Non-goals

- **No scenario, `check()`, sample-count, or threshold change** —
  `DEFAULT_THRESHOLD_PCT`, `TRIAGE_K`, and every scenario stand; the
  statistics of the JUDGMENT are the subject.
- **No verdict-vocabulary or summary-format change** — strike-once
  flags reuse `"noise"`.
- **No baseline caching or stored-numbers comparison** — the
  five-release incident that banned stored baselines
  (`release.yml:137-143`'s comment) stays banned; the baseline retry
  re-measures the downloaded binary in-run.
- **`selfcheck` mode, `_perf/compare.tl`, `_perf/run.tl`,
  `_perf/baseline.tl` untouched.**
- The `json_decode_large` drift observation stays on this item's
  record as evidence for a FUTURE bisect if it flags again under the
  reproduction rule — not this slice's to chase.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _perf/gate_test.tl _perf/compare_test.tl`
   passes, including the four new tests.
3. `grep -c "baseline-bin" _perf/gate.tl` prints at least `2` (usage
   and the option loop; today `0`), and
   `grep -c "baseline-bin" .github/workflows/release.yml` prints `1`
   (today `0`) — or, if the workflow push was refused, the follow-up
   item's id is recorded on this item and the grep is deferred to it.
4. `wc -l < _perf/gate.tl` and `wc -l < _perf/gate_test.tl` each
   print at most `500`.
5. `git diff --name-only origin/main` prints exactly
   `_perf/gate.tl`, `_perf/gate_test.tl`,
   `.github/workflows/release.yml` (the third absent only in the
   refused-push case), plus `.cosmic-coverage` if and only if the
   coverage ratchet asked.
6. The next release run after landing is the live proof; it is the
   reviewer's and the owner's to read, not this slice's to trigger.

## Enablement

none needed. Both failure modes are pinned to specific log lines from
run 33034667243; the injection seam makes every new path testable
without benchmarks; the one external risk (workflow-push permission)
has its fallback stated in Change.
