## Evidence

Measured across the `/work 9 --routine` orchestrator pass on 2026-09-04
(friction log `friction-2026-09-04-work9.md`, filed alongside this item):
**2 independent builders this pass hit the 500-line file cap while adding
a test their own item's spec asked for**, on two different files in the
same `_work/*_test.tl` cluster:

- build-VbI3_FiHP-d6f1cc41: `_work/gitgate.tl` and `_work/gitverbs.tl` were
  BOTH already sitting exactly at 500 lines before the item started; the
  spec's requested addition ("append ... to the one-claim refusal") had
  to be packed onto existing lines (widening them past the 90-column
  house style, which is explicitly not gated) rather than adding new
  lines, taking 3 edit/`wc -l` iterations to fit.
- build-nwzb_73yW-d6f1cc41: `_work/gitgraph_test.tl` was at 493/500 lines
  (7 lines of headroom) before the item started; the spec's requested new
  pinning test needed ~12-14 lines even written compactly, causing 2 file-
  length lint failures (505, then 501 lines) before the builder abandoned
  a new test function in favor of extending an existing one that already
  had most of the needed setup — roughly 10 minutes and several iterations.

In both cases the item's own `## Change`/`## Evidence` said nothing about
the target file's headroom, and the builder only discovered the tightness
by hitting the cap live (`wc -l`, `--check lint`) mid-implementation — the
first step's own instruction to `wc -l` before editing DID catch it before
any wasted implementation, but did not prevent the repacking cost itself.

This is not a one-off: `_work/*.tl` and `_work/*_test.tl` (the board
tool's own source, actively being refined by exactly the kind of items
this pass works) is evidently a cluster of files that sit at or near the
500-line cap as a matter of course, because this pass's own churn keeps
adding to them.

## Change

A `wc -l`-based check, surfaced at spec-writing or spec-review time rather
than discovered by the builder: when an item's `## Change` names a file
whose current line count is within ~20 lines of the 500-line cap, the
spec bar (`gitboard help bar` / whatever validates an item before it's
pullable) flags it — either as a hard refusal requiring the spec to note
a repacking/splitting plan, or as a printed warning on `gitboard show`
alongside other spec-bar problems, so a refiner sees it before the item
is pulled rather than a builder discovering it live.

Exact mechanism (orchestrator's suggestion, refiner's call): extend
whatever already computes file-overlap warnhings for `next`'s "overlaps"
annotations (`_work/overlap.tl`?) to also check line-count headroom for
each file an item's spec Change section names, using the same `wc -l`
the `fallible-returns`/file-length lint already enforces.

## Non-goals

Not raising or removing the 500-line cap itself ([D39] settles that with
no prose exemption) — this is purely an earlier-warning mechanism so a
refiner or builder sees the tightness before implementation, not a policy
change to the cap.
