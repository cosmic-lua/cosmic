## Change

`gitboard next` stops offering the merge of an accepted item whose
blockers still bind, and names the hold when that is what stalls
everything.

Reproduced 2026-08-29 on a scratch board (board head f10c9b6): an
item with `verdict: accept`, `pr: 7`, then
`gitboard block ID PEER --reason "hold the merge"`; the peer is open,
so the edge binds (`show` renders `blocked by:`), yet

    gitboard-next: finish 3Ib1Jdko the slice — 3Ib1Jdko is accepted,
    awaiting merge — finishing beats starting

— the merge of deliberately-held work is the board's top offer, and a
session that follows it merges past the recorded landing order.

The change, in `_work/action.tl` (334 lines now —
`wc -l < _work/action.tl`):

1. In `phased_action`, the rung that emits the accepted-awaiting-
   merge `finish` action skips items where
   `flow.is_blocked(i, index)` — the same predicate `show`'s
   `blocked by:` heading and the status `[blocked]` mark derive
   from, so the three can never disagree. ONLY the accepted rung
   changes: a blocked item still building or under review stays
   offered (a blocker records landing order; building and judging
   are not landings).
2. Count what was skipped (a `merge_held` field on the `Phased`
   record, alongside the existing `suppressed`), and in
   `next_action`, when no rung fired and `merge_held > 0`, return
   `kind = "none"` whose reason names it:
   `"N accepted item(s) wait on open blockers — resolve the
   blockers; their merges are held"` — placed with the other
   terminal answers, before the intake rung, in the same shape as
   the doing-bound answer added at 04de3ee.

Tests in `_work/action_test.tl`: the reproduced scenario — an
accepted item with a binding blocker is not offered as finish, and
with nothing else on the board `next` returns `none` naming the
held merge; ending the blocker (resolution set) makes the same item
the `finish` offer again; a blocked item in `building` substate is
still offered to its own session.

## Non-goals

Existing verdict-line formats unchanged; the new terminal reason is
a new line, not an edit to one. `done` itself is untouched — this
gates the OFFER, and `done`'s own merge verification stays the
enforcement. No blocker check on the review or building rungs, and
none on `take`'s finishing motions.
