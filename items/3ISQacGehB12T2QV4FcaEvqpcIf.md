## Change

Refreshed 2026-08-29: the original prose evaluates a merge queue
against the deleted `land` verb; the contract to evaluate against
today is accept → the orchestrator merges at accept time → `done`
verifies the accepted PR merged (origin-gated, `_work/gitverbs.tl`
cmd_done). The re-run tax it measured is unchanged in kind: when
main moves while a PR waits, the merge is refused, the branch
updates, and the full suite re-runs (~4-5 min per landing at
parallel hours).

This is a RESEARCH item — the deliverable is recorded findings and
a decision, not code:

1. Measure the current tax: from the Actions history of the last
   ~20 merged PRs, count how many paid a base-update re-run cycle
   (a second `pull_request` run on a merge-base update commit) and
   sum the minutes. Paste the query and the table into this sidecar
   under `## Result`.
2. State the contract changes a GitHub merge queue imposes on THIS
   system, concretely: accept-time merge becomes accept-time
   enqueue; `done`'s merged-verification still holds (the queue
   merges eventually) but its timing decouples from the accept;
   `verdict_head` pins the reviewed head while the queue tests a
   different merge result; the required-check set moves to the
   queue's `merge_group` context (pr.yml would need a `merge_group`
   trigger). Name every gitboard site that assumes merge-at-accept
   (`grep -n "merge" _work/gitverbs.tl _work/review.tl`).
3. Decide adopt or reject against the measured tax, and record the
   tradeoff: adoption is a decide-skill record on main
   (docs/decisions/) plus follow-up items; rejection is the
   evidence written into this sidecar's `## Result` and the item
   ended. Either way the queue's serialization-vs-latency tradeoff
   is stated with today's numbers, not vibes.

## Non-goals

No settings changes, no workflow changes, no gitboard changes in
this item — those are follow-ups the decision mints if it says
adopt.

## Result

Decided 2026-08-29 by the goal owner: ADOPT, scoped to main. The measurement half is moot — the decision came by fiat with the tax already characterized in kind. Adoption surface (measured against the live machinery): (1) pr.yml gains a merge_group trigger — the gate-status composite from PR 1522 already posts gate/* statuses to github.sha on non-PR triggers, which on merge_group IS the candidate head, so required contexts are satisfied by queue runs unchanged; concurrency cancel-in-progress is already scoped to pull_request only. (2) Ruleset: operator enables the queue on main, squash method, gate/* contexts required. (3) Orchestrator lands main PRs by enabling auto-merge (enqueue) on accept; the merged pull_request.closed event drives done, exactly the existing notification flow. (4) cmd_done and verdict_head need no code change — done's merge verification only shifts in time, and verdict_head keeps meaning "the head the reviewer judged". (5) Main only: board takes direct state pushes every few minutes and would thrash a queue; board PRs keep merge-at-accept. Follow-up item filed for the buildable slice (merge_group trigger + decision record + skill sentence); the ruleset flip is the operator's.
