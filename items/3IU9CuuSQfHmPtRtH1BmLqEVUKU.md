## Goal

`next` under concurrency: sessions fan out instead of converging on
one item, blocked items are skipped wherever the WIP limits still
hold, and the offer-to-claim race window closes. Owner-directed
(2026-08-27, in chat): implement candidate lists with seeded
within-tie shuffle, the fused claim (`next --take`), the starvation
reorder, the blocked-skip in the finish branch, and the `set`
claim-overwrite guard, directly as one machinery change.

## Change

1. `_work/priority.tl`: `sorted(list, pos, seed?)` — an optional seed
   replaces the final id tiebreak with a seeded-hash tiebreak, so
   items the comparator ties (same band, own, unblocks) order
   differently per session while every judged ordering stands.
2. `_work/flow.tl`: `queued` passes the seed through.
3. `_work/decision.tl`: `Action` gains `alternates: {Action}`.
4. `_work/action.tl`: the phased half returns up to K=4 candidates
   (land, then reviewable, then finishable, then pullable capped at
   free `do` slots), primary first, crossing rungs when the top rung
   is thin. `unheld` skips blocked `do` items (they cannot be
   finished). The starvation rule fires before intake only when it
   BINDS (`ready` at limit with every member blocked); otherwise
   intake runs first and starvation is the fallback when intake has
   nothing.
5. `_work/gitview.tl`: `next` prints alternates under the guidance.
6. `_work/gittake.tl` (new) + `next --take`: claim the offered
   candidate in the same invocation — `review` for a review, `move
   do --claim` for a pull — walking the candidate list on refusal
   (the CAS/claim refusal is the collision signal), re-syncing and
   recomputing once when the list exhausts. Non-claimable kinds
   report as today.
7. `_work/gitgate.tl` `set_in_place`: overwriting a live foreign
   claim in place now needs `--force --why`, the same rule the move
   verb applies — closes the observed silent-takeover hole.
8. Tests: `_work/action_pick_test.tl` (new; starvation binds vs
   falls back, blocked finish skip, alternates shape and caps,
   seeded fan-out), additions to `_work/priority_test.tl` (seeded
   tiebreak properties), `_work/gitclaim_test.tl` (the in-place
   guard; the test pinning the old silent overwrite updates),
   `_work/gittake_test.tl` (new; take claims past a lost candidate).
9. `docs/flow-review.md`: the starvation-rule change recorded with
   its tripwire.

## Non-goals

No WIP limit changes; blocked items keep occupying their phase's
slots and arrivals at limit are still refused. No new phases or
parking columns. No change to verdict/review distance rules. Bare
`next` stays a read.

## Acceptance

- `bin/cosmic --make ci` on the board branch ends `ci: PASS`.
- `gitboard next` on a board whose ready items are all blocked but
  under limit answers refine/promote (when plan/backlog feed exists),
  and `unblock` only when ready is at limit or intake is empty —
  pinned in `_work/action_pick_test.tl`.
- Two named sessions asking the same board are offered different
  first candidates when the top tie-group holds several — pinned.
- `next --take` claims the primary or a later candidate and says
  which; a candidate another session claimed is skipped, not fought.
- A same-phase `move ID <phase> --claim X` over a live foreign claim
  is refused without `--force` — pinned in `_work/gitclaim_test.tl`.
