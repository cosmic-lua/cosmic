> Capture note, 2026-08-19: this spec was refined to the ready bar while `plan` sat over limit (18/12) and `new --parent` was refused. Attach under 3HyArM3A (the G3 cast epic) when plan drains; the verification below ran against a worktree at f420391 and is dated.

## Goal

G3 — an honest type layer, no escape hatches, via the epic "measure and
drive down the as-cast count" (parent). This is the epic's wave 3: the
checker-verified pure deletions.

## Change

Delete 12 `as` casts that the checker no longer needs — the cast and its
`-- cast:` justification comment come off the line together, nothing else
on the line changes. Measured 2026-08-19 at `f420391` (main), these are
ALL surviving sites of the three reason strings:

```
$ git grep -n -- "-- cast:.*partial record fixture\|-- cast:.*stub verb\|-- cast:.*partial literal" -- "*.tl"
_make/law_test.tl:22,29          {…} as types.File / as Verb   (2 sites)
_make/policy_test.tl:24,50       as types.File / as Verb       (2 sites)
_make/project_test.tl:272-277    as File (list elements)       (6 sites)
_make/stage_test.tl:24           as File                       (1 site)
cosmic/sse_test.tl:409           as sse.Event                  (1 site)
```

Verified deletable 2026-08-19, not inferred: in a worktree at `f420391`
all 12 casts were deleted and the full gate re-run —
`o/bin/cosmic --make check` ended `check: PASS (506 files)` and
`o/bin/cosmic --make test` over the five files ended `test: PASS (5
files)`. The table literals satisfy the records structurally; no `is`
guard or replacement idiom is needed anywhere.

The cast ratchet will then hold a floor above the tree's count, so
regenerate the committed baseline and commit it in the same PR:
`bin/cosmic --make run _build/casts.tl --baseline`. Expected result,
computed from today's floor (455 across 136 files, the exact tree
count): 443 across 131 files — each of the five files drops to zero
casts and leaves the baseline entirely.

The census's wave 3 also named "enum rows (3)"; measured today, no
deletable enum-reason site remains (`git grep -in -- "-- cast:.*enum"`
returns only widenings, boundary translations, and one pairs()-erasure —
all justified). Wave 3 is these 12 sites, no more.

## Non-goals

- no other cast site moves, whatever the neighboring diff invites — the
  remaining 443 are other waves' work.
- no type or record changes: `types.File`, `Verb`, and `sse.Event` stay
  exactly as declared.
- no change to `_build/casts.tl` (the gate) beyond the baseline regen it
  prints; the `TREES` list is settled (PR #1276).

## Acceptance

- `bin/cosmic --make test _make/law_test.tl _make/policy_test.tl _make/project_test.tl _make/stage_test.tl cosmic/sse_test.tl` ends `test: PASS (5 files)`.
- `git grep -c -- "-- cast:" -- "*.tl" | awk -F: '{s+=$NF} END {print s}'` prints 443.
- `bin/cosmic --make ci` ends `ci: PASS` — which includes the cast
  ratchet agreeing with the regenerated baseline.

## Enablement

none needed — pure deletion under an existing gate; the ratchet's own
failure message names the regen command quoted above, and the
deletability claim is pre-verified against the current tree (see Change).
