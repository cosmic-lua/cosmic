## Evidence

`_work/doctrine.tl:279` (help orchestrate): "agents never run board
verbs, so no agent needs this worktree or push rights to `board`". The
emitted review brief (`gitboard brief review ID`, "Recording your
verdict" section) instructs the reviewer to run `o/bin/gitboard
verdict ... --session <minted>` from `/home/user/cosmic/o/board`.
Three reviewers did exactly that today (16:28, 17:20-ish,
17:37 verdict commits on the board log), each from the orchestrator's
shared board worktree, while the orchestrator was also committing
there. An orchestrator reading `help orchestrate` first would refuse
to spawn a reviewer with that brief.

## Change

`_work/doctrine.tl`, the orchestrate topic's first bullet: replace the
absolute with the rule the tool already implements — "agents never
run board verbs, with one exception: a reviewer records its own
`verdict` under the session the orchestrator minted for it, so the log
never shows a builder accepting its own work; every other board move
(take, drop, spec, done) stays the orchestrator's". Add one sentence
on the shared worktree: the verdict verb syncs before it writes, so a
reviewer and the orchestrator committing concurrently is supported;
nothing else should be run there by an agent.

`_work/doctrine_test.tl`: pin the sentence with a `find`.

## Non-goals

No change to the review brief or the verdict verb.
