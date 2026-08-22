## Goal

G6 hygiene after the gate change (#1313): the release's measurement
artifacts should each have exactly one stated role, and the workflow
should not measure what nothing reads.

## Evidence

Since 08998b0e the perf gate measures the previous release's BINARY
in-job; the stored perf.json asset is no longer any gate's input. Three
loose ends, measured 2026-08-22:

- release.yml's "measure the release" step still runs the suite twice
  (`--out o/perf/perf.json`, then `--out o/perf/selfcheck.json`), and
  its comment says the second run exists "so the compare step below
  has an A/A self-check" — but gate.tl's usage states "SELFB: written
  by the A/A pass" and gate_inner measures into selfcheck_b itself
  when escalation is reached (_perf/gate.tl:157-163), so the
  pre-measured file is overwritten or unread. That second run is ~2
  min of every release spent producing an input nothing consumes;
  this predates #1313 but the gate change makes it plain.
- baseline.tl's default --asset is still perf.json, which no perf
  caller uses anymore (the perf gate passes --asset cosmic-lua; the
  size gate passes --asset size.json).
- perf.json remains a useful published RECORD (each release's own
  numbers on its own runner, human history), but no comment says that
  is now its only role.

## Direction

Small, one PR: drop the redundant selfcheck pre-measure (or re-point
it as a documented warmup, if measured to matter); fix the step
comment to state perf.json's record-only role; flip baseline.tl's
default asset or make --asset required so the default cannot silently
drift from any real caller. _build/workflows_test.tl already greps
this step's shape — extend it to pin whichever role wording lands.
