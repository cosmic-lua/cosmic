> Capture note, 2026-08-19: attach under 3HyArM3A (the G3 cast epic)
> when a plan slot opens. A research slice: its deliverable is recorded
> evidence and follow-up wave items, not code.

## Goal

G3 — the cast epic's wave 6, the re-measure the epic itself mandates:
the census classified 86 sites as `narrowing-gap` against the
documented narrowing limits, and one of those limits was since measured
FALSE (#1191: early-exit `is` guards DO narrow — the correction landed
with `cosmic/teal_narrowing_test.tl` pinning the real behavior). An
unknown share of the 86 is therefore removable today with no tl patch
at all, and every wave planned on the stale classification is
mis-sized until this runs.

## Change

A measured re-classification, worked in a throwaway worktree against a
built binary (the wave-3 slice's method: delete, `--make check`, record):

1. Enumerate the current `narrowing-gap` population: the census's five
   sub-classes (terminal-call gap 21, `pcall` returns 10, `or` fallback
   7, record fields 5, generics 7 — counts as of 2026-08-15) re-grepped
   against today's tree by their reason strings, with the exact
   commands and today's counts recorded.
2. For each site whose reason string names a limit #1191 falsified
   (early-exit guard shapes), delete the cast in the worktree and run
   `o/bin/cosmic --make check`; a clean check moves the site to
   `removable-now`.
3. Deliverable, written back into THIS item's spec: the re-classified
   table (per sub-class: still-blocked vs removable-now, with counts
   and commands), and one filed follow-up wave item per removable
   cluster big enough to slice (the wave-3 shape: enumerated sites,
   pre-verified deletions, floor delta) — filed as captures if the plan
   column is at limit, with attach notes.
4. What stays blocked gets its blocking limit named precisely (which
   tl behavior, pinned by which `teal_narrowing_test.tl` case or
   missing from it) — that list is the D5 upstream-first backlog's
   input, and a limit NOT pinned by the narrowing test gets a test case
   added to the follow-up item that would need it.

## Non-goals

- no cast deletions land from this slice — verification happens in a
  throwaway worktree; the deletions are the follow-up waves' diffs.
- no tl patch work (`3p/tl/tl_patch.tl`) — this slice only names what
  a patch would buy, sized by measurement.

## Acceptance

A research slice, reviewed per review.md's research clause:

- this item's spec carries the re-classified table, every count beside
  the command that produced it, dated and at a named commit.
- each `removable-now` cluster ≥ 8 sites has a filed follow-up item id
  recorded here.
- the reviewer re-runs at least the sub-class totals and spot-checks
  two removable claims by deleting those casts and running
  `o/bin/cosmic --make check`.

## Enablement

none needed — the method is wave 3's, already proven on this epic; the
narrowing facts to test against are pinned in
`cosmic/teal_narrowing_test.tl`.
