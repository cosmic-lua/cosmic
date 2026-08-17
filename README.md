# board

The board branch: cosmic's board and the machinery that operates it,
together, on an orphan history. This branch shares no files with
`main` — it is append-only, never rebased, never force-pushed;
rewriting published state history would break every checkout's
push-as-compare-and-swap at once.

## What lives here

```
items/       the board: one <ksuid>.tl per item (cosmic.literal data)
             with its spec prose in the matching <ksuid>.md
_work/       the machinery: gitboard (CLI), gitverbs (mutations),
             gitview (reads), gitgate (the WIP and ready gates, and
             the commit-and-publish every mutation goes through),
             store (git-backed persistence), flow (the rules), item
             (the record), ksuid (ids) — plus the legacy label-board
             tool, kept while GitHub issues remain the inbound queue
bin/cosmic   the trust root: fetches the one pinned cosmic and execs it
```

Roles derive from the graph — there is no kind field: a ranked root is
a goal, an unranked root is a finding awaiting triage, an item with
open children is a container being decomposed, and a parented leaf is
workable (the only thing that holds a board phase).

## Using it from a cosmic checkout

The machinery lives HERE, not on main, so the verbs run from this
worktree — `--dir` then defaults to it and needs no argument:

```
git worktree add o/board board     # once per checkout
cd o/board
bin/cosmic --make fetch            # once, on a cold worktree
bin/cosmic --make run _work/gitboard.tl status
bin/cosmic --make run _work/gitboard.tl next
```

Every mutation is ONE commit here, and publishing it is a push. A
rejected push is the compare half of a compare-and-swap: the tool
rebases onto whoever moved first, re-checks the WIP invariant against
the merged board, and refuses if the limit now binds — dropping its
own commit whole, so a mutation never half-lands. Two sessions editing
the SAME item cannot rebase past each other; that refusal names the
items and leaves the checkout clean rather than mid-rebase. Reads need
no network and no token.

Run `bin/cosmic --make ci` before pushing machinery changes; the
`board` workflow runs the same gate on every push to this branch.

GitHub keeps two jobs: pull requests carry fixes and their review;
issues are the inbound queue, imported here as findings at triage.
