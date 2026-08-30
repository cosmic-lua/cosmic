## Change

Measured 2026-08-30 on the current board head (post-#1539):
`cmd_block` (`_work/gitgraph.tl:164+`) stores reasons per blocker in
the item's `block_reason` map (`_work/item.tl:59` declares
`block_reason: {string: string}`; `reasons[blocker] = reason` on add,
`= nil` on remove), but the existing-edge branch refuses BEFORE ever
reading the incoming reason: `if not remove and had then return
gate.verdict_line(verb, false, ("%s already waits on %s")...)` — so a
stale reason cannot be corrected except by unblock+block (two commits,
and a race window where the edge is gone). The guard's own comment
says a second block "would silently rewrite the first one's" — which
is true only because the code never compares them.

The change, in `_work/gitgraph.tl` (`cmd_block`) only: when the edge
already exists and the incoming `--reason` DIFFERS from
`block_reason[blocker]`, replace the stored reason and commit (one
mutation; verdict line states the reason was updated, e.g. `<id8>
still waits on <id8> — reason updated`); when it is IDENTICAL (or the
existing-edge call carries the same text), keep the current refusal so
re-runs stay no-ops with no empty commits. `blocked_by` is untouched
in the update path. Update the comment above the branch to describe
the compare-then-replace rule.

Tests in `_work/gitgraph_test.tl`: re-block with a new reason updates
`block_reason[blocker]` and leaves `blocked_by` unchanged; re-block
with the identical reason refuses without committing; unblock still
clears the map entry. Mutation-verify the compare (make the update
path fire on identical reasons too, watch the no-op test go red).

## Non-goals

No new verbs or flags. No change to unblock, the deadlock check, or
the require-a-reason refusal. cmd_new/cmd_attach untouched (recently
reworked by #1539 — rebase cleanly on current board).
