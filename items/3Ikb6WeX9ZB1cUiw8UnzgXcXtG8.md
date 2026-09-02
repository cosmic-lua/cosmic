## Evidence

`docs/decisions/d25-outcomes-and-instruments.md:28` says "the method
lives in `skills/work/decompose.md`" for the paired-comparison
tournament that ranks outcomes. cosmic-lua/cosmic#1610 (item
`cem3_qFxC`) creates `skills/work/decompose.md`, but by its own
Non-goals it carries only two sections — the VERIFICATION item form
and held-root intake behavior — so D25's pointer still lands on a file
that does not describe the tournament. Re-measure at pull time:
`grep -n 'tournament\|paired' skills/work/decompose.md docs/decisions/d25-*.md`.

## Change

`skills/work/decompose.md`: add the section D25 points at — the
paired-comparison tournament as the board actually runs it: a
comparison is `gitboard compare A B` ("A outranks B"), the derived
order is the transitive closure over those edges (`_work/priority.tl`,
`gitboard help system`), age breaks ties, an unplaced item is invisible
to every queue until compared or attached, and a comparison that would
put NEW work above existing work belongs to the goal owner (posted as a
pair, applied as a `compare` when it arrives). Cite `gitboard help
system` and `gitboard help compare` for the mechanics rather than
restating them; the section is the procedure (when to run a
tournament, which pairs to ask, how the result lands), not the tool
reference. Keep the two sections #1610 added as they are.

## Non-goals

- No change to `docs/decisions/d25-*.md` or `docs/goals.md`.
- No change to `_work/` tooling.
