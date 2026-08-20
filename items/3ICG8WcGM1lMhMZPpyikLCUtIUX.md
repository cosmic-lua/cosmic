## Evidence

2026-08-20, hit live: a spec passed the ready bar, was pulled, built,
reviewed, and had to be BOUNCED because its measurements described a
tree that no longer existed. The measurements were correct when
written and nothing re-checked them at promotion.

The instance, 3IBFBWtc (fuzz child 6, corpus persistence). Its
`## Problem, measured 2026-08-20` cited:

    _fuzz/driver.tl       215 lines
    _fuzz/driver_test.tl  312 lines

Both exact — as of `0b2907b9~1`. Its own sibling, child 5 (3IAXDNwC,
"crash isolation via cosmic.child"), then merged as `0b2907b9` and
added 197 lines to the driver and 116 to its test:

    $ git show 0b2907b9~1:_fuzz/driver.tl      | wc -l   # 215
    $ git show 0b2907b9~1:_fuzz/driver_test.tl | wc -l   # 312
    $ git show 0b2907b9:_fuzz/driver.tl        | wc -l   # 390
    $ git show 0b2907b9:_fuzz/driver_test.tl   | wc -l   # 406

3IBFBWtc's `## Change` was written against 215/312 and reads "two
edits to one module — `_fuzz/driver.tl` — plus new tests in
`_fuzz/driver_test.tl`". At 390/406 that shape is no longer
buildable: the tests alone land at ~609 lines against the hard
500-line cap (`_tool/lint.tl:24`, and `_fuzz/**` is not in
`.cosmicignore`), and the code half fits only at 499/500.

The cost was a full round trip: pulled, implemented (PR #1297,
head `4ec56c6a`), reviewed, `request changes`, then bounced to `plan`
for a re-measure and a re-shaped spec. Two further multipliers:

1. **The reviewer inherited the stale number.** The review text reads
   "note driver.tl is 215 lines — the spec's shape lands well under
   the 500-line cap", carrying the spec's figure forward rather than
   measuring. A shape was then REQUIRED on the strength of it.
2. **The implementer split the files correctly for the real cap but
   did not bounce**, so the deviation arrived as a diff surprise
   instead of a spec question — which is what the review objected to.
   Both halves of the loop were reasoning from the same stale premise.

## Why this is a class, not an instance

Child 5's own spec measured its pre-sibling tree the same way
(3IAXDNwC: "via `wc -l _fuzz/driver.tl`, 285 lines of headroom under
the 500-line cap") and then consumed 175 of that headroom itself. A
decomposed epic lands children SEQUENTIALLY into the same files, so
every unlanded sibling's measurements are invalidated by the ones
that land first. The ready bar checks that a spec HAS its sections
and that the item has a position; nothing checks that what the spec
measured is still true, and an item can sit in `plan`/`ready` for
days while its siblings land. Board-wide, `plan` dwell has a median
of 275 min and sat at-or-over its limit 94% of the last 70 h
(`_work/flow.tl`'s recorded stint walk), so the window for drift is
the normal case, not an edge.

The failure is silent in both directions: a spec whose numbers went
stale reads exactly like one whose numbers hold, and the reviewer has
no signal either.

## Fix shapes (not chosen here)

- **Cheapest, prose-only**: the ready bar's spec grammar requires a
  measurement to name the commit it was taken at ("measured against
  `origin/main` at `<sha>`"), so a reader can date it. Costs nothing
  mechanical; catches nothing automatically.
- **Mechanical**: `gitboard check` (and the `move … ready` gate)
  refuses, or warns, when a spec cites a commit that is not the
  current `origin/main` tip, or is more than N commits behind. Needs
  the spec to carry the sha, so it composes with the above.
- **Targeted at the real trigger**: when an item's SIBLING under the
  same parent ends, flag every remaining open sibling as
  measurement-suspect — that is the exact event that invalidated
  3IBFBWtc, and the board already knows both facts.
- **Review-side**: `review.md` says a reviewer re-runs the Acceptance
  commands; extend that to re-measuring any figure the spec's `Change`
  reasons from, before requiring a shape that depends on it.

Any of these would have turned this bounce into a refinement, which
is the cheap end of the same correction.
