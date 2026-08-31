## Evidence

Found while building 3I1Rvbva (coverage --baseline: refuse a bad
rewrite instead of clamping a good one, cosmic-lua/cosmic#1576), which
deleted `_tool/coverage/baseline.tl`'s never-raise clamp so a row can
now raise back on regen, not just lower. That PR's own scope was
`baseline.tl` + `baseline_test.tl` only; two other spots still describe
the pre-clamp-removal one-way behavior and are now stale:

- `_make/policy.tl`'s `write_baseline` prints `"... row(s) lowered; a
  floor only moves up by hand — see cosmic/coverage/SENSITIVITY.md"`
  after every successful `--baseline` write. That claim is false since
  #1576: a floor can now raise automatically on regen, and the message
  doesn't mention raises at all.
- `cosmic/coverage/SENSITIVITY.md` (around lines 50-52) documents the
  old one-way clamp ("A rewrite lowers only the rows this machine
  measures... and leaves every other row exactly as committed"), which
  is no longer accurate post-#1576.

**Sharper, since 3I1Rvbva's own rework (PR #1576, commit 82f9d175):**
this is not only a stale-wording problem. `_make/policy.tl`'s
`write_baseline` (around lines 107-121) iterates
`baseline.lowered(floor, fresh)` and unconditionally labels every row
it returns `"coverage: baseline LOWERS ..."`, folding all of them into
the final `"N row(s) lowered"` count. Since #1576 widened
`baseline.lowered()` to report rows that moved in EITHER direction
(the same root cause `corpus_guard` had, fixed in 82f9d175 via a new
`dropped_count` helper that counts only genuine drops), `write_baseline`
has the identical bug: a `--baseline` run where rows only RAISE will
still print those raises as "LOWERS" and count them into "N lowered".
This was found live, running a real `--baseline` regen against the
committed floor, by the session reworking 3I1Rvbva after review — not
merely inferred from the diff.

## Change

Two files:

- `_make/policy.tl`'s `write_baseline`: stop treating every
  `baseline.lowered(...)` entry as a drop. Use the same
  drops-vs-raises distinction `_tool/coverage/baseline.tl`'s
  `corpus_guard` now uses (a `dropped_count`-style helper, or
  equivalent) to print raises and drops separately (or at minimum
  correctly label which is which), so the final summary message is
  honest in both directions instead of calling every moved row a
  "LOWER". Re-read `_tool/coverage/baseline.tl`'s post-#1576 shape
  (`lowered()`, `dropped_count()`) at pull time — reuse its logic
  rather than re-deriving it.
- `cosmic/coverage/SENSITIVITY.md` (around lines 50-52): update the
  stale one-way-clamp description to describe the current behavior —
  a `--baseline` regen writes the honest measurement in both
  directions (raises and lowers), narrated either way, guarded by the
  corpus breadth check that refuses when more than half the floor's
  rows would drop.

Re-verify exact wording and line numbers against the current tree at
pull time (#1576, including its rework commit, must be merged to main
first).
