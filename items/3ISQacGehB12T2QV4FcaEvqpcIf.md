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
