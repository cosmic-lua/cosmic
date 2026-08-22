`ready` and `do` dwell measure when a transition was RECORDED, not
when work started and stopped, so the two phases the WIP argument
turns on are the two the instrument cannot yet speak for.

## Evidence

Found 2026-08-22 by the agent implementing 3I4BaVrL (whilp/cosmic#1324)
and verified independently against the live branch log:

    21:32:02  move 3IHGsSpm plan -> ready
    21:32:04  move 3IHGsSpm ready -> do
    21:36:47  move 3IHGsSpm do -> check

A two-second `ready` dwell, because one orchestrating session issues
the promotion and the pull back to back. The implementing work then
happens on a branch, between no two board commits, so `do` dwell is
the interval from "a session decided to start" to "a PR existed" —
which for a fan-out wave is dominated by how the orchestrator batched
its moves.

The aggregate this produces, from `gitboard stats` on the same log:

    ready  dwell n=55 median 54m   p90 15h41m
    do     dwell n=64 median 6m    p90 22m
    check  dwell n=49 median 2h47m p90 5h46m
    land   dwell n=44 median 55s   p90 2h11m

`do` reading SHORTER than `check` is the tell. `check` and `land`
dwell do not have the problem: they span a real wait on a reviewer
and on a merge, and both ends are board commits by construction.

## Why it might matter

3IHGs0n6 wants to cut `plan` to its limit and cites the flow review,
which review.md says is argued from measured dwell. The instrument
that arrived to serve it is trustworthy for `check` and `land` and
misleading for `ready` and `do` — and nothing in its output says so.
A limit tuned against a 6-minute `do` median would be tuned against
an artifact of how one session batched its board writes.

## Directions, not a decision

- Have `stats` mark the phases whose dwell is recording-bound, so the
  caveat travels with the number instead of living in a PR body.
- Record work boundaries rather than inferring them: a `do` entry
  already names its claim, and the PR's own first-commit time is a
  real start that the item's `pr` field can reach.
- Accept the limitation and use dwell only for `check` and `land`,
  which is what the flow review most needs anyway (both measure the
  queue in front of a reviewer).

## Where the evidence is

whilp/cosmic#1324, and `git log --format='%cI %s'` on the board
branch for any item pulled during a fan-out wave.
