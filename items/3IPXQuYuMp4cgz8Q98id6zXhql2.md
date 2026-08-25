## Goal

G3 — an honest type layer. After the checker learns the four guards it
ignores and the test sites take `check.must`,
`docs/design/nil-flow.md`'s census leaves **109 library sites in 79
files** where a `T | nil` reaches a non-nil sink with no guard anywhere.
These are the census's real finds and the last thing standing between
the tree and a strict nil-flow mode.

## Change

**This item is a container, not a slice.** 109 sites across ~50 library
files is far past one session's diff, and the sites do not share a fix:
each one is a judgment between two mechanisms the census names.

Decompose it by TREE, so the children are file-disjoint and can run in
parallel. The census's per-file counts give the cut; the heaviest, from
`docs/design/nil-flow.md`:

- `cosmic/fs/**` — `tree.tl` 10, `find.tl` 8, `walk.tl` 7, `path.tl` 6
- `cosmic/**` outside `fs/` — `time.tl` 7 (already its own item)
- `_eval/**` — `checks/json-cli.tl` 8 and siblings
- `_tool/**`, `_make/**`, `_docs/**`, `_perf/**`, `_cli/**`, `_build/**`

Each child slice states its own site list (re-derived, not copied — the
census is dated `e7ac1580`) and closes each site by ONE of:

- **A guard at the site** — the value really can be nil and the code has
  no answer. `if not x then return nil, "..." end`, or the module's own
  error shape.
- **A narrower signature at the producer** — the producer cannot fail in
  the way its type admits, so no caller should pay. This is the better
  fix wherever it applies, and the one that shrinks the census faster
  than the site count suggests.

The split between the two is the judgment no command makes, and it is
why this is not a mechanical sweep.

## Non-goals

- **Do not close a site with a cast.** `as` moves the lie from the type
  to a comment; every cast added here would land in
  `_build/casts_baseline.tl` and be someone else's slice.
- **Do not close a site with `check.must`.** It throws; AGENTS.md
  forbids it in library code.
- **No checker change.** The four narrowing rules are a separate item;
  this one is edits at sites.
- **Do not widen a return type to make a site compile.** Pushing the
  union one caller further out is not progress.

## Acceptance

Stated per child slice. For this container, the outcome is observable:
re-running the census's Method over the tree reports **zero** library
sites in the trees its children covered, and `bin/cosmic --make ci`
ends `ci: PASS`.

## Enablement

Blocked in practice, not by an edge: run this AFTER the narrowing-rule
slice, or the children will spend their diffs on sites the checker was
about to stop flagging. The census's class sections say which of the
109 each mechanism touches.
