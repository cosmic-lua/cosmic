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

## Correction — 2026-08-27: the first Direction item is now false

`3IVGNOMt` landed as whilp/cosmic#1464 and **publishes
`o/perf/selfcheck.json` as a release asset.** So the claim above —
"that second run is ~2 min of every release spent producing an input
nothing consumes" — no longer holds, and dropping the run would now
delete data rather than reclaim waste.

What the second run produces is the project's only free full-suite
**same-binary A/A control pair**: two readings of one binary, on one
runner, in one job, each carrying its own `meta.bin_sha` and
`meta.timestamp`. That is exactly the longitudinal record the
cross-session level work kept having to reconstruct by hand
(3IU0GxoA spent two probe brackets and three review rounds on it).

The observation the bullet rests on stays TRUE and is worth keeping:
on the escalation path `gate_inner` does re-measure into
`selfcheck_b`, so the pre-measured file is overwritten there. What
changed is the conclusion. Both provenances are now stated in
`release.yml`'s own comment, and both are valid A/A halves:

- clean run — the published file is the measure step's second reading;
- escalated run — it is the gate's own control measurement, which
  `controls` then feeds to `triage_many`, so on that path it does
  decide the exit code.

**The remaining two Direction items are untouched and still real:**

- `baseline.tl`'s default `--asset perf.json` matches no real caller
  (the perf gate passes `--asset cosmic-lua`, the size gate
  `--asset size.json`) — flip the default or make `--asset` required
  so it cannot silently drift.
- nothing says `perf.json`'s role. Note the wording now has to cover
  `selfcheck.json` too, and the two files' roles differ: one is the
  record, the other the control.

So this item is smaller than it was, and its first bullet is now a
non-goal rather than a task. Re-scope it to the `--asset` default and
the role wording before pulling it; do not carry the deletion forward.
