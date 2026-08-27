## Evidence

Found 2026-08-27; this is the revisit 3IU0aIel's resolution reserved.

3IU0aIel deliberately skipped plan/ready refinement claims: "moves are
already serialized by push-as-CAS, WIP limits cap the racers, and the
measured waste there was spec churn, not builds — revisit if measured."
It has now been measured: 3IVEqtkH records two sessions handed the same
refine of 3IUBNQZZ out of the same bounce — one refined and moved it to
`do`, the other spent its whole pass refining the same item and replaced
the first's spec wholesale mid-build. 3IUFODun (in flight) closes the
WRITE half with `spec --base`: the loser now gets a refusal instead of a
lost update. It does not touch the DISPATCH half: `_work/intake.tl`
reads no claims at all, so under concurrent looped sessions `next` hands
the same highest-placed plan item to every session that asks, and the
--base refusal arrives only after the duplicate refinement is already
spent — a full pass of waste per collision, recurring by construction.

The shape that fits the existing machinery: the same fusion reviews got.
`next --take` on a refine writes a short claim (the review lease's 1h
scale, not the build's 4h — refinement dwell is minutes to an hour), and
the intake rung skips a plan item under another session's live refine
claim exactly as `reviewable` skips a claimed review. Cheap single-commit
mutations (attach, compare, done, block, promote) stay CAS-only: a lease
there adds takeover ceremony for races that cost seconds, which is the
half of 3IU0aIel's reasoning that still holds.
