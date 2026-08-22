## Goal

G8 — the flow system. review.md's flow-review procedure says a limit's
findings are recorded in _work/flow.tl's module doc comment, and that a
plan queue confirmed oversized twice "is cut, not kept". Both halves
are now due.

## Evidence

The 2026-08-22 quality review re-ran the flow review over the board's
full history (595 commits, 138 items, 6 days) and confirms the
existing flow.tl tripwire a second time:

- plan 40 against LIMITS.plan 12 (3.3x), while ready held 1, do 0,
  check 1, land 0 — the right side ran dry between refinement passes.
- flow efficiency ~8%: median 3.1 h first-pull-to-done inside a
  38.9 h median creation-to-done; the difference is queue age, almost
  all in plan. This reproduces the comment's "173 min pickup latency
  against a 6 min do" with two more days of data.
- intake 90 vs ended 76 over the window (+14 net open).
- queue age is the measured cause of 3 of 7 review bounces (stale
  spec measurements — 3ICG8WcG, now mitigated at pull but not cured:
  refresh shrinks the damage, only a shorter queue shrinks exposure).
- balance: G8 held 16 open children while no product goal held more
  than 5; 14 of 40 plan items were the flow system filing findings
  about itself.

## Direction

One refinement session: append this review's numbers and date to
flow.tl's doc-comment evidence block (the skill says findings land
there); then execute the cut the rule prescribes — end or merge plan
inventory toward the limit, oldest and least-placed first, preferring
cuts in the G8 hardening tail over product items; record what was cut
with done --reason not-planned so the record shows the decision.
