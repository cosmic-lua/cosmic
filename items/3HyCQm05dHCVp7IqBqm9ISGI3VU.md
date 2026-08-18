Imported from whilp/cosmic#1120.

## Goal

G6 — the defining paths, ratcheted (docs/goals.md). Intake: G3 and G8 are driven by
epics #1112 and #1117; G6 is the next ranked outcome with real slack.

## Outcome (observable)

- Every release carries a `perf.json` asset (the harness's results under the released
  binary) and a compare verdict against the previous release's asset — so per-release
  history is the chain of release assets, with no new storage system.
- The compare is a hard release gate once enough history exists to set a defensible
  noise policy (child slice, blocked on the data).
- A peer table (the same defining-path metrics for CPython, Node, Go) is published
  with each release, reporting standing without gating (goals.md: "it never gates").

## Evidence (2026-08-15 survey)

The measurement half of G6 exists; the ratchet half does not:

- `_perf/` has ~36 checked scenarios across 17 bench modules, and the defining paths
  are covered: startup (`startup_run_lua`, `startup_run_teal`), checker latency
  (`teal_check_module`), embed cycle (`embed_run_tree`, `embed_extract_tree`,
  `embed_run_startup`). The noise-aware compare gate (`_perf/gate.tl compare` /
  `selfcheck`) exists and is tested.
- No workflow runs any of it: the only mention of perf in `.github/workflows/` is an
  artifact-path exclusion (`!o/perf` in pr.yml). release.yml runs `--make ci` under
  the release binary but never measures it.
- No perf results are stored anywhere, so there is no release-over-release history
  and nothing to ratchet against.
- The peer table exists only as a sentence in goals.md.

## Walls

The agent cycles-per-task ratchet is G1's (the eval instrument), not this epic's.
Never weaken a scenario or its `check()` to make a number pass (optimize skill rule);
the release gate slice must fail on wrongness (a scenario check failing) even while
the speed compare is report-only.

## Children

- [ ] #1121 — release perf: measure, publish, and compare every release against the last
- [ ] #1122 — promote the release perf compare to a hard gate (blocked: needs history)
- [ ] #1123 — peer table v1: the defining paths against CPython, Node, Go

The gate and peer-table slices stay in shaping until the first slice's data exists —
the gate's noise policy and the peer table's fairness rules are decisions that want
real runner measurements, not guesses.