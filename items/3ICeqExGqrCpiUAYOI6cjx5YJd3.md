A scheduled (unattended) session cannot land an item whose PR targets
`main`: `gitboard land` gets a 403 from GitHub and the loop cannot advance
past `land`.

Measured 2026-08-21, session `routine-jafqqr`, on item `3I1J9Xhg` (PR
#1295, accepted at head `7d41e0f1`, base `main`):

```
$ o/bin/gitboard land 3I1J9Xhg
gitboard-land: REFUSED (403: this token may not merge PR #1295 into the
base branch — a permission refusal, not the diff. The accept stands and
PR #1295 stays in land — ask a maintainer to squash-merge PR #1295.
PUT /repos/whilp/cosmic/pulls/1295/merge: HTTP 403: Merging into a
protected base branch is not permitted for this session type.)
```

It is the BASE that decides, not the session. The same session landed
`3I3z2gOF` (PR #1286, base `board`) minutes later without trouble:
`gitboard-land: merged PR #1286`. So a scheduled session can drain `land`
for board-branch work and never for product work — which is most of it.

`gitboard land` handles the refusal correctly: it names the cause, leaves
the accept standing and the item in `land`. The problem is the loop around
it. `next` is finish-first, so it keeps answering `finish 3I1J9Xhg` on
every re-run, and there is no way to look past an action this session is
not permitted to take. A scheduled run therefore parks on the first
`main`-based accept it reaches, however much refinement, triage or
implementation the board is holding — the same run had `plan` at 13/12 and
`triage` at 29/8, and only got further work done by stepping around the
ordering by hand.

The two directions worth weighing (a priority comparison, not a call an
unattended session should make alone):

- give the scheduled session a token that may merge into a protected base,
  so the loop drains `land` itself; or
- let the loop step past an action it cannot perform — either `next`
  learning that a phase is unavailable to this session (the way
  `--session` already withholds a session's own reviews), or a
  session-level "cannot merge" fact the ordering reads.

Until one of those lands, every unattended run ends by asking a maintainer
to squash-merge `main`-based PRs by hand, and accepted product work sits in
`land` between runs.

## Second occurrence, and it is not repo-specific

Measured 2026-08-21, session `claude-hitmco`, on item `3I7LDODd` (PR
whilp/cosmopolitan#267, accepted at head `ef3973ec`, base `master`):

```
$ o/bin/gitboard land 3I7LDODd
gitboard-land: REFUSED (403: this token may not merge PR #267 into the
base branch — a permission refusal, not the diff. The accept stands and
PR #267 stays in land — ask a maintainer to squash-merge PR #267.
PUT /repos/whilp/cosmopolitan/pulls/267/merge: HTTP 403: Merging into a
protected base branch is not permitted for this session type.)
```

Same refusal, different repository and a different base branch name, so
the fact is about protected bases generally rather than about
`whilp/cosmic`'s `main`. The loop parked identically: `next` answered
`finish 3I7LDODd` on the re-run, with `plan` at 13/12 and `triage` at
31/8 behind it.

The session had reviewed and accepted that PR immediately before, so the
run's whole yield was one verdict — the review reached `land` and stopped
there. That is the cost this capture is measuring: an unattended run
converts at most one item per wake, and only when the item ahead of it is
not a merge.
