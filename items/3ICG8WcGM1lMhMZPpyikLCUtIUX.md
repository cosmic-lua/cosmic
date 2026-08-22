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

## Direction (chosen 2026-08-22): optimistic freshness at pull

Staleness splits into two kinds, and only one of them should cost a
replan. The check moves to the moment of claim, and it is optimistic:
re-measure, proceed unless the item's core value is compromised.

1. **Re-measure at claim.** When `next` hands an item into `do`, the
   session's first act is to re-run the spec's measurement commands
   (the ready bar already requires each claim to carry its command;
   #1288 mechanized bounds make much of this a literal re-run). This
   costs minutes; the bounce it replaces cost 3IBFBWtc a full
   build+PR+review round trip.

2. **Detail drift: refresh and proceed.** If the numbers moved but the
   shape holds — the Problem still exists, `## Change` is still
   buildable as written, `## Acceptance` still runs as written,
   `## Non-goals` are untouched — the session updates the measured
   lines in place (`gitboard spec`, one commit, stamped "re-measured
   at pull") and proceeds. No bounce, no replan. The reviewer judges
   against the pull-time numbers, so every figure the review reads is
   fresh by construction.

3. **Value drift: back to plan.** If a refreshed fact breaks the
   shape — the specified Change is no longer buildable as written
   (3IBFBWtc's file-cap arithmetic), the problem no longer exists,
   Acceptance cannot pass as stated, or the fresh number would change
   a DECISION the spec encodes — the item returns to plan, exactly as
   today, but detected in minutes at claim instead of after the
   implementation.

4. **The line a session may not cross:** a claim-time refresh may
   update FACTS, never decisions. "The spec says 215 lines and the
   file is now 390" is a refresh if the split still fits, a bounce if
   it does not; choosing a different split is plan's job, per the
   skill's rule that ambiguity is never resolved from memory
   mid-implementation.

5. **The mechanical half stays cheap:** re-run the mechanized bounds;
   inside tolerance is silent, outside tolerance asks the session for
   exactly one judgment — "Change and Acceptance as written?" — and
   the two answers are the two paths above.

This is the same optimism the board's own push already uses: proceed,
validate at the boundary, pay only when the conflict is real. The
earlier fix-shapes remain as complements (sibling-landing flags are
the natural trigger for an early re-measure; the reviewer's re-run is
the backstop), but the primary mechanism is the claim-time check,
because that is the last moment the correction is still free.
