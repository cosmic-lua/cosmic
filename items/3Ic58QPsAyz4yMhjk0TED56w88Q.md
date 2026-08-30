Evidence (review of PR #1541, 2026-08-30): `_make/clean.tl`'s `run()`
appends the summary detail ", kept the verified bootstrap"
unconditionally whenever `kept > 0` — reproduced by hand with a fake
worktree child and no bootstrap: the per-skip line correctly printed
`clean: kept board (git worktree)` but the final verdict still said
`clean: PASS (o, kept the verified bootstrap)`. Cosmetic; the change
is the summary detail reflecting what was actually kept (bootstrap,
worktree(s), or both), with a small test asserting the worktree-only
wording.
