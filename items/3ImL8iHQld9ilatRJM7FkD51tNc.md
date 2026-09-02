## Evidence

Found by the builder of item `3IlIvjaZzuYcnrxR1E9Vw5h1szQ` («Vw5h_1szQ»,
cosmic-lua/cosmic#1639, the PR-only-wording fix for a research handover's
take refusal, accept outcome, finish note and verdict line) while fixing
the adjacent readers on that same walk.

`_work/action.tl:339`'s `ph.merge_held` terminal message — "N accepted
item(s) wait on open blockers — resolve the blockers; their merges are
held" (introduced by item `3ITiik4DnJIrOxnYocdjPnc1uBA`, #1501) — also
speaks PR-only. It fires when an accepted item is blocked from finishing
by an open blocker, `done` being withheld until the blocker resolves.
An accepted research handover blocked the same way has no merge to hold
back (`done` skips the merge read entirely once `pr` is 0, per #1639's
same finding for the other readers on this walk) — so the message
misnames a blocked handover's situation, promising a merge that will
never come, the same class of bug #1625 and #1639 already fixed on the
take-refusal/accept-outcome/finish-note/verdict-line path.

## Change

`_work/action.tl`'s `merge_held` counting/message: distinguish a blocked
accepted diff (whose merge really is held) from a blocked accepted
handover (nothing to merge — `done ID` is simply withheld pending the
blocker), and word the `kind = "none"` reason accordingly — by kind, or
counting/naming both together without claiming a merge for a handover.
Follow the same per-kind pattern #1639 established for the other four
readers on this walk (`gitgate`, `action`'s accept reason, `gitverdict`,
`guidance`, `gitshow`).

A test on a result-item fixture (blocked, accepted, `result ~= ""`)
confirming the reason no longer says "merges are held" for a handover.

## Non-goals

- No change to `merge_held`'s counting/gating logic itself (whether a
  blocked accepted item is offered) — only the reason's wording.
- No change to the diff-item wording path, already correct.
