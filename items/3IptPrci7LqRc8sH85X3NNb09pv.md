## Evidence

`ke6b_yr5h` ("G3 wording: the measured cast floor is 23, so decide
whether zero as-casts stays literal", PR cosmic-lua/cosmic#1664) chose
wording 3 for G3's `measured by`/`win condition`: zero `as` casts
outside what `3p/tl/tl_patch/cast.tl`'s `COSMIC_CAST_LEGALITY=1` rule
permits, un-gated. That wording's own spec line says it "additionally
files (does not do) the un-gating work: one item per refused class
from the census, blocked on a `bin/cosmic.pin` bump (a checker rule
that refuses in-tree code is the cold-build case)."

The builder session did not file these — board-item creation is the
orchestrator's job, not a builder's — and flagged it back with a
starting point: `docs/design/cast-legality.md`'s per-class table
(measured under `COSMIC_CAST_LEGALITY=1`) names, per refused class, a
concrete repair, e.g. userdata boundary: reorder the nil guard in
`cosmic/embed/init.tl:103` before the cast; generic T: widen
`merge_impl`'s return type in `cosmic/deep.tl`; metatable access: wrap
`getmetatable` behind a declaration returning `any`.

## The question / decompose

This is a decompose task, not a build: once `ke6b_yr5h`/#1664 merges
and cast-legality.md's per-class table is re-read against current
`origin/main`, split this into one item per refused class the table
names, each:

- describing the concrete repair `cast-legality.md` already names for
  that class,
- `blocked_by` a `bin/cosmic.pin` bump to a release built from a tree
  carrying the un-gated `COSMIC_CAST_LEGALITY` rule (the cold-build
  rule in CLAUDE.md: an un-gated rule that refuses in-tree code is
  exactly the case generation 1 catches only on a cold build),
- parented under the same G3/casts goal as `ke6b_yr5h`.

Do not build any of these yet — the pin-bump blocker isn't itself
filed/available. File the pin-bump item first if it doesn't already
exist on the board, then the per-class items blocked on it.
