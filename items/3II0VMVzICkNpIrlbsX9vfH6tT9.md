`gitboard land --force` on a pull request whose head moved since the
accept merges a diff no reviewer read, and leaves no record that it
did.

## Evidence

Introduced 2026-08-22 by whilp/cosmic#1323 (item 3ICDNJmQ), which
made `land` compare the accepted head against the request's current
one. Three paths now exist and only two of them record a
substitution:

- head matches: merge, nothing to say.
- already merged with a moved head: the item completes, and
  `gitland.tl` prints
  `gitboard-land: WARNING PR #N merged at HEAD7 but the accept judged HEAD7`
  — the discrepancy is in the log.
- `--force` with a moved head: `review.blocks_land`'s refusal is
  skipped along with every other, the merge proceeds, and **nothing
  is printed**. `--why` is recorded in the commit trailer for the
  `done`, but it says why the force was used, not that the head
  merged differs from the head judged.

The spec for #1323 asked for exactly this (`--force` "skips the new
refusal along with the others") and the implementing agent flagged
the asymmetry rather than widening its diff, which is why this is a
capture and not a bug in that PR.

## Why it might matter

The warn-and-record principle #1323 applied to the already-merged
branch is the same principle: where the merge cannot be prevented,
the substitution should still be legible afterwards. A forced land is
the one path where a session DECIDES to merge an unreviewed head, so
it is the path where the record matters most, and it is the only one
that keeps no record.

## Direction, not a decision

Print the same WARNING line on the forced path before merging. One
line, the same text, moved out of the `p.merged` branch so both
reach it.
