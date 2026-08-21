A scheduled (unattended) session cannot land an accepted item: `gitboard
land` gets a 403 from GitHub and the loop cannot advance past `land`.

Measured 2026-08-21, session `routine-jafqqr`, on item `3I1J9Xhg` (PR
#1295, accepted at head `7d41e0f1`):

```
$ o/bin/gitboard land 3I1J9Xhg
gitboard-land: REFUSED (403: this token may not merge PR #1295 into the
base branch — a permission refusal, not the diff. The accept stands and
PR #1295 stays in land — ask a maintainer to squash-merge PR #1295.
PUT /repos/whilp/cosmic/pulls/1295/merge: HTTP 403: Merging into a
protected base branch is not permitted for this session type.)
```

`gitboard land` handles the refusal correctly — it names the cause, leaves
the accept standing and the item in `land`. The problem is the loop around
it: `next` is finish-first, so it keeps answering `finish 3I1J9Xhg` on every
re-run, and there is no flag to look past an action this session is not
permitted to take. A scheduled session therefore stops at the first accepted
item it cannot merge, however much refinement, triage or implementation work
the board is holding — the same run had `plan` at 13/12 and `triage` at 29/8.

The two directions worth weighing (a priority comparison, not a call this
session should make alone):

- give the scheduled session a token that may merge into a protected base,
  so the loop drains `land` itself; or
- let the loop step past an action it cannot perform — either `next`
  learning that a phase is unavailable to this session (the way `--session`
  already withholds a session's own reviews), or a session-level "cannot
  merge" fact the ordering reads.

Until one of those lands, every unattended run ends by asking a maintainer
to squash-merge by hand, and the accepted work sits in `land` between runs.
