## Change

Evidence (review of PR #1541, 2026-08-30, reproduced by hand):
`_make/clean.tl`'s `run()` appends the summary detail ", kept the
verified bootstrap" unconditionally whenever `kept > 0` — with a fake
worktree child and no bootstrap present, the per-skip line correctly
printed `clean: kept board (git worktree)` but the final verdict
still said `clean: PASS (o, kept the verified bootstrap)`. The
change, in `_make/clean.tl` (+ `_make/clean_test.tl`): the summary
detail names what was actually kept — bootstrap, worktree(s), or
both (e.g. `kept the verified bootstrap`, `kept 1 git worktree`,
`kept the verified bootstrap and 1 git worktree`) — derived from the
same counts run() already has. Test: the worktree-only case asserts
its wording and the absence of "bootstrap"; the bootstrap case keeps
its existing wording. Mutation-verify (revert to the unconditional
string, watch the worktree-only wording test go red). Note the test
file is runner-mode: do NOT self-call new test functions.

## Non-goals

No behavior change to what clean keeps or removes (just merged —
untouched); the per-skip lines stay as they are.
