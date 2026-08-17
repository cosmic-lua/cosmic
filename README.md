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
_work/       the machinery: gitboard (CLI), gitverbs/gitview (verbs),
             store (git-backed persistence), flow (the rules), item
             (the record), ksuid (ids) — plus the legacy label-board
             tool, kept while GitHub issues remain the inbound queue
bin/cosmic   the trust root: fetches the one pinned cosmic and execs it
```

Roles derive from the graph — there is no kind field: a ranked root is
a goal, an unranked root is a finding awaiting triage, an item with
open children is a container being decomposed, and a parented leaf is
workable (the only thing that holds a board phase). The full design:
docs/design/work-state/README.md.

## Using it from a cosmic checkout

```
git worktree add o/board board          # once per checkout
bin/cosmic --make run _work/gitboard.tl status --dir o/board
bin/cosmic --make run _work/gitboard.tl next --dir o/board
```

Every mutation commits here and publishes (push); a rejected push
rebases onto the winner, re-checks the WIP invariant against the
merged board, and refuses if the limit now binds. Reads need no
network and no token.

GitHub keeps two jobs: pull requests carry fixes and their review;
issues are the inbound queue, imported here as findings at triage.
