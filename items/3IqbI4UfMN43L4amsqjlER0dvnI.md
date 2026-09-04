## Evidence

In the `/work 9 --routine` pass on 2026-09-04 (friction log
`friction-2026-09-04-work9.md`), the orchestrator briefed multiple
reviewer subagents to run `gitboard verdict` in the SAME shared board
worktree the orchestrator itself uses (`/home/user/cosmic/o/board`) —
following `gitboard help review`'s own text ("the reviewer claims the
review first... and records the verdict itself") and the emitted
`gitboard brief review ID` template, both of which point every
reviewer at "the board worktree" as if there is one canonical
checkout to run commands in, with no instruction to use a separate
clone.

Concretely: reviewer session `review-RxN2_253n-1e1a9125` ran
`gitboard verdict ... accept --session review-RxN2_253n-1e1a9125` in
that shared worktree. Its own report says the first attempt returned
"the push was rejected... commit is still local", and an immediate
retry returned "REFUSED: ... already carries an accept — land it" —
which the reviewer read as a benign race (its own verdict having
already landed under a concurrent push). In fact the opposite
happened: the commit recording the accept verdict was made LOCALLY in
the shared worktree but never reached `origin/board` — a concurrent
`git fetch`/rebase/push cycle from another process using the SAME
local checkout (either this pass's own concurrent review agent for a
different item, or the independently-observed concurrent orchestrator
session `3df204e9` also working this board at the same time) reset
the shared worktree's local ref out from under the reviewer's commit
between its local commit and its push. The verdict was invisible on
`origin/board` (confirmed: `git diff HEAD origin/board -- items/<id>.tl`
showed the `verdict`/`verdict_head`/`verdict_spec` fields present only
in the stray local commit, absent upstream) until the orchestrator
noticed `gitboard sync` refusing with "this checkout carries local
commits origin/board does not have... not possible to fast-forward",
manually diagnosed it, ran `git rebase origin/board` (clean), and
pushed by hand.

Cost: the PR (#1685) was actually merged on GitHub before the
orchestrator discovered the board's own record of its acceptance had
never published — the two systems (GitHub PR state and board state)
were briefly inconsistent, and required tool-adjacent manual git
surgery (a `rebase`/`push` outside any `gitboard` verb) to reconcile.
Multiple gitboard-driven agents (reviewers, and potentially
concurrent orchestrator sessions) racing on ONE shared local git
checkout is a real hazard the doctrine doesn't warn about: builders
get "one fresh worktree per agent" explicitly; reviewers get no such
rule for the BOARD-side checkout they push to.

## Change

Either: (a) `gitboard verdict` (and `take`) detect a rejected push and
automatically fetch+rebase+retry (bounded, e.g. 3 attempts) before
reporting failure, so a transient race self-heals without a human or
orchestrator noticing an inconsistent local state; or (b) `gitboard
help review` and the emitted review brief instruct each reviewer to
clone its OWN board checkout (`git clone <board-repo> --branch board
/tmp/review-board-<handle>-<session>` + `bin/cosmic --make build`)
rather than sharing the orchestrator's, mirroring the "one fresh
worktree per agent" rule builders already get for the PRODUCT repo.
(a) is the better fix on its own (it also protects the orchestrator's
own sequential `take`/`verdict`/`done` calls against a concurrent
session, which (b) does nothing for); (b) is complementary and cheap
to also do.

## Non-goals

Not a locking/consensus redesign for the board — git's own
fast-forward check is already the correctness mechanism; the gap is
only that a caller sharing a stale local checkout can silently produce
an ORPHANED LOCAL commit instead of a clean, visible refusal to retry.
