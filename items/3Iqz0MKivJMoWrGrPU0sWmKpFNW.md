## Evidence

Found while building «FacE_b8sh» (PR #1695, "gitboard: refuse review
while CI on the head is still running"). That item's spec attributed
`next`'s CI-awareness to `_work/action.tl` ("`next` (`_work/action.tl`):
a reviewable item whose head is `running` is rendered `ci running`
under doing and not offered as head"), and the builder implemented
exactly that: `phased_action`/`next_action` in `_work/action.tl` now
take an optional `CiStates` map and correctly step a running/red
reviewable item out of the offer when given one.

But `action.tl` is architecturally pure — no `store.Store`, no `gh`,
no GitHub reach of its own — and its only caller for a live `next` run
is `_work/gitview.tl`'s `cmd_next` (which already does the analogous
live read for item ages via `claim_ages`). `gitview.tl` was not in
FacE_b8sh's stated file scope, so nothing calls `gh.head_checks` to
build a `CiStates` map and pass it to `action.tl` in production: the
new CI-awareness is implemented and unit-tested (fixture-driven) but
INERT for an actual `gitboard next` invocation today. Confirm at
pickup: `grep -n 'head_checks\|CiStates' _work/gitview.tl` (expect no
output before this item lands).

## Change

`_work/gitview.tl`'s `cmd_next`: build a `CiStates` map the same shape
`action.tl` expects, by calling `gh.head_checks` once per
`STAGE_REVIEW` item that carries a `pr` field (mirroring the existing
`claim_ages` live-read pattern for staleness), and pass it through to
`next_action`/`phased_action`. Off-line (no GitHub reach) `head_checks`
already returns `nil` per call per «FacE_b8sh»'s Evidence, and every
degrades-to-today's-behavior guarantee that item already tested at the
`action.tl` layer should hold unchanged through this wiring — add
one integration-level test in `_work/gitview_test.tl` (or a sibling,
if that file is near its own 500-line cap — check first) confirming a
live `next` actually renders "ci running"/"ci red — builder's" for a
fixture PR in those states, not just that `action.tl` can.

## Non-goals

No change to `_work/action.tl`, `_work/gh.tl`, `_work/gitverbs.tl`, or
`_work/brief.tl` — all already correct per «FacE_b8sh»; this item is
the wiring only.
