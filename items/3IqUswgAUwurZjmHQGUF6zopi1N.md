## Evidence

The 2026-09-04 routine orchestrator created nine worktrees with
`git worktree add <path> origin/main --detach`, then read in each
emitted brief that the worktree "is on a fresh branch `<id[:8]>`", and
removed and recreated all nine with `-b <branch>`: 18 extra `git
worktree` calls. The branch name is the id's first 8 characters (`help
build` step 3), but the only place the convention appears at claim
time is the brief, which is emitted after the worktree exists in the
sequence `help orchestrate` gives (claim, worktree, brief, spawn).
`take`'s success line (`_work/gitverbs.tl:234`, `"%s is yours%s%s"`)
prints the 8-character id and nothing about the branch.

## Change

`_work/gitverbs.tl:234`: a pull's success line becomes
`<id8> is yours — branch <id8> off <base>` where `<base>` is the
item's `base` field or the repo default (`main` for
`cosmic-lua/cosmic`, `master` for `cosmic-lua/cosmopolitan`, the
board's own `base` when set). A review claim and a `--pr`/`--result`
handover keep their current lines. `_work/doctrine.tl`, orchestrate's
worktree bullet: "one fresh worktree per agent, on the branch `take`
names, never detached".

`_work/gitverbs_test.tl`: pin the line for a cosmic item and a
cosmopolitan item.

## Non-goals

`take` does not create the worktree.
