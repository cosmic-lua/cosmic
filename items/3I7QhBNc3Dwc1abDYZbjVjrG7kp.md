> Capture note, 2026-08-19: attach under 3HyRdT1J (G8) when a slot
> opens — the writer half split out of 3I29nhZC's refinement, which
> owns the reader half (verify-before-install).

## Goal

G8 — the flow system: two `--make` invocations against one tree must
serialize instead of corrupting each other's `o/`. The three loud
races 3I29nhZC's evidence records (zip reading a half-cleared staging
dir, ENOENT on a mid-write input, ENOTEMPTY on a mid-write clear) are
all one process reading what another was writing.

## Constraints, measured 2026-08-19

`cosmo.unix` has NO `flock` (probed: `u.flock` is nil), so the classic
advisory lock is unavailable without a cosmopolitan binding addition
this slice deliberately does not wait for. `u.kill` exists and
`O_EXCL` exists, so the portable design is an exclusive-create
lockfile.

## Suggested shape (for the refinement that drives this to ready)

- `o/.make.lock`, created `O_CREAT|O_EXCL`, holding `pid <started-at>`.
- Acquisition at the `--make` entry point for every verb that touches
  `o/` (all but `help`); on conflict, print ONE line naming the holder
  pid, then poll until free.
- Stale takeover: when `unix.kill(pid, 0)` says the holder is gone,
  remove and retry; where the liveness probe is unsupported (Windows
  smoke lane — verify), fall back to an age bound, measured against
  the slowest CI build before choosing the number.
- Release on every exit path; a crash leaves the stale-takeover path
  as the recovery, which the tests pin.
- Tests: two child cosmic processes contending over one tree — the
  fixture harness in `_make/testdata` plus `cosmic.child` covers it;
  the loser waits rather than corrupting, and a lockfile with a dead
  pid is taken over.

The remaining open question for refinement: whether acquisition lives
in `_make/init.tl`'s entry or deeper (the converge re-exec at
`_make/converge.tl` re-enters `--make` — the lock must not deadlock
against the re-execed self; likely release-before-exec or an
inherited-lock marker). Measure the converge path before speccing.

## Non-goals

- no flock binding on whilp/cosmopolitan for this — file that upstream
  only if the lockfile design proves insufficient.
- no cross-tree locking (two checkouts stay independent), no lock on
  read-only verbs.
