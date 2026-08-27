## Goal

G8 — the flow system (parent 3HyRdT1J). Concurrent sessions do not
duplicate refinement: the dispatch half of the collision 3IVEqtkH
recorded, complementing 3IUFODun's write half (`spec --base`). A plan
item one session is refining is skipped by every other session's
`next` while the refiner keeps committing, and is anyone's again an
hour after they stop.

## Change

Six source files and one new test file, all on the `board` branch.

**1. `_work/health.tl` (207 lines) — the refine lease.** Add
`REFINE_LEASE_S < const > = 60 * 60` and `is_refine_stale(i, ages)`:
true for a claim-carrying item whose last board commit is older than
the refine lease. The mirror of `is_review_stale` over `claim` instead
of `reviewer`; an absent age never reads as stale. An hour, the review
lease's scale, because refinement dwell is minutes to an hour — spec
commits are the liveness signal exactly as verdicts are for reviews.

**2. `_work/intake.tl` (211 lines) — the refine draw skips held
items.** `intake_action` (line 114) gains a trailing optional
`session?: string`. The refine draw (line 125,
`first_unblocked(b, "plan", index, pos)`) additionally skips an item
whose `claim` is non-empty, not this session's, and not
`health.is_refine_stale` — give `first_unblocked` an optional
`(session, ages)` pair the promote draw does not pass. Count what was
skipped and append `", N under refinement"` to the refine reason so
the skip is visible.

**3. `_work/action.tl` (495 lines — 5 of headroom, so no net
growth).** Pass `who` through: line 407 becomes
`intake.intake_action(items, b, index, pos, aged, who)`. One line
changed, zero lines added.

**4. `_work/gittake.tl` (146 lines) — take fuses the refine claim.**
`claimable` adds `"refine"`. `claimed` for a refine: if the item's
claim already names this session, return true (idempotent re-take);
else `verbs.cmd_move(s, c.item.id, "plan", session, 0, false, "",
false, session) == 0` — a same-phase move is `set_in_place`, which
writes the claim and publishes, and refuses a live foreign claim so a
lost race falls to the next candidate exactly as pull and review do.

**5. `_work/gitverbs.tl` (329 lines) — ready clears the claim.** In
`cmd_move`, a rightward arrival into `ready` sets `it.claim = ""`
(beside the existing leftward-return clearing). `ready` is "nobody's
until a session pulls it", and a refine claim surviving into ready
would make `action.pullables` — which has no lease check — skip the
item for every other session forever.

**6. `_work/guidance.tl` (154 lines).** The `refine` notes gain one
sentence: claim it first — `next --take` does, or `move ID plan
--claim <you>` on an item already in plan; a refine claim idle past
the hour lease is anyone's again.

**7. New `_work/refine_claim_test.tl`** over `fixture.init_shared`
and pure boards:
- `test_refine_skips_a_live_foreign_claim` — a plan item claimed by
  another session with a fresh age is not offered to this session;
  the reason counts it.
- `test_refine_offers_a_stale_or_own_claim` — the same item with age
  past `REFINE_LEASE_S` is offered again, and the claimant is always
  offered their own.
- `test_take_claims_a_refine` — `cmd_take` on a board whose action is
  refine writes this session's claim on the item (two clones: the
  second session's `next` then skips it), and a second take by the
  claimant reports without a duplicate mutation.
- `test_ready_arrival_clears_the_claim` — `cmd_move` plan -> ready on
  a claimed item leaves `claim` empty.

## Non-goals

- No claim guard on a rightward move of a plan item somebody else is
  refining: `set_in_place` already refuses a live claim overwrite,
  and takeover semantics stay the existing `--force --why` rules.
- No `record_builder` from a refine claim: `set_in_place` does not
  record builders, which is what take-mode uses — a refiner stays
  eligible to review the eventual build.
- No change to `pullables`/`unheld`, the 4-hour do lease, or the
  review lease.
- No new item field: the existing `claim` carries the lease, and the
  phase says which lease applies.
- No edit to 3IUFODun's territory (`cmd_spec`, `store.tl`): this diff
  touches `cmd_move`, not `cmd_spec`, so the two merge independently.

## Acceptance

- `bin/cosmic --make ci` from the board worktree ends `ci: PASS`.
- `bin/cosmic --make test _work/refine_claim_test.tl
  _work/intake_test.tl _work/gittake_test.tl _work/action_test.tl
  _work/converge_test.tl` passes, including the four tests above.
- `wc -l` of every touched file is at most 500; `_work/action.tl`
  stays at 495 (measured 2026-08-27: health 207, intake 211, action
  495, gittake 146, gitverbs 329, guidance 154).

## Enablement

none needed — board-branch modules only, gated by `bin/cosmic --make
ci` from the worktree exactly as the board workflow gates pushes, no
blocker items. 3IUFODun (in flight) is complementary, not a
dependency: different functions, independently mergeable.
