`item.validate` accepts a `blocked_by` list containing the same id more than
once, so a duplicated blocker is representable board state that no gate
reports.

## Evidence (verified 2026-08-18 on the board branch)

`items/3I1JDVLmiWji4tVjJ8dkxK7MuJk.tl` holds four entries naming two items:

```
["blocked_by"] = "3I1J83ZrdZ2D027WFZhGm2WB2mM 3I1J9Xhgg9FfvW4fxvQ2UZ3LS37 3I1J83ZrdZ2D027WFZhGm2WB2mM 3I1J9Xhgg9FfvW4fxvQ2UZ3LS37",
```

`gitboard check 3I1JDVLm` returns `meets the ready bar` — the duplication is
invisible to validation. `item.tl:132-135` walks `blocked_by` and checks only
that each entry is a ksuid; nothing checks the list for repeats. Compare
`beats` directly below it (`item.tl:137-142`), which gets a second check (an
item may not outrank itself) — the two list fields are validated to different
depths.

A scan of all 140 item files finds exactly one affected item: `3I1JDVLm`,
4 entries / 2 unique. No item has duplicate `beats`.

## Root cause: migration, not the verb

`cmd_block` cannot produce this today. `gitverbs.tl:189-206` rebuilds the list
through a `seen` set, so re-blocking on an id already present is idempotent,
and `unblock` drops every copy of the named blocker in the same pass — so the
state is self-healing on the one path that touches it.

`git log -- items/3I1JDVLm*.tl` has a single commit: `d1cdc9fe` ("board: the
work system and its state, on their own history"), the migration onto the
orphan branch, and the duplicated line arrives already duplicated in it. This
is imported label-era state that predates the dedup in `cmd_block`, not a
defect the current verb can reach.

## Why it is worth a card anyway

Impact today is cosmetic and narrow:

- `gitview.tl:218-219` renders `blocked by: <a> <b> <a> <b>` in `show`.
- the `block`/`unblock` verdict line reports `(%d blocker(s))`
  (`gitverbs.tl:218`), which counts entries, so it would over-report.
- `flow.tl:174,203` iterate the list to decide blocked-ness; a repeated id
  resolves the same way twice, so ordering and the blocked flag are correct.

The general point is the one worth settling: the board's invariants are
enforced by `item.validate`, and this is a case where the WRITER (the verb)
maintains an invariant that the VALIDATOR does not state. Any state that
arrives by another route — a migration, a hand-edit under the skill's
"work around a missing verb once by editing the item file" allowance, a
merge — can therefore carry it silently.

## Candidate change (not refined)

Add the duplicate check to `item.validate` for `blocked_by` (and `beats`,
which has the same exposure), then repair `3I1JDVLm`'s list. Deciding
whether validation should REJECT the file or whether the reader should
normalise on load is the open question — rejecting turns one imported item
into a board that fails `check` until repaired, which argues for repairing
first and tightening second, in that order.

## Refined to ready, 2026-08-19

The instance is repaired: 3I1JDVLm's list was rebuilt with the verbs
(`unblock` removes every copy of an id), so it now holds exactly one
open blocker and the tree carries NO duplicated entry — measured:
`grep -c '3I1J83Zr.*3I1J83Zr\|3I1J9Xhg.*3I1J9Xhg' items/*.tl` is 0.
What remains is the gate that keeps it true.

## Goal

G8 — the flow system: representable board state is validated state; a
list field's invariants hold by `problems()`, not by convention.

## Change

In `_work/item.tl` (227 lines), `problems()` (line 102): the
`blocked_by` walk (lines 132–135) additionally refuses a repeated id —
collect seen ids in a set, and a second occurrence appends
`("blocked_by repeats %s"):format(b)`. Give `beats` the same rule in its
walk directly below (lines 137–142): it is the same class of list field,
validated today to a different depth (it refuses self-reference but not
repeats). In `_work/item_test.tl` (111 lines): pin all four — a repeated
blocker refused, a repeated beat refused, distinct entries in each
accepted.

## Non-goals

- no dedup-on-decode: silently folding repeats would hide the writer bug
  that produced them; the gate refuses, the writer fixes.
- no change to the `block`/`unblock` verbs — `block` already refuses an
  edge that exists (its `kept` rebuild), so the only writers of repeats
  are file edits, which is exactly what validation exists to catch.
- no other validation deepening.

## Acceptance

- `bin/cosmic --make test _work/item_test.tl` ends `test: PASS (1 files)`.
- `bin/cosmic --make ci` ends `ci: PASS` on the board worktree — which
  requires the repaired state above to stay repaired, since `status`
  validates every item.

## Enablement

none needed — the instance is already repaired via verbs (see above), so
the slice cannot be refused by its own new gate; the walk to extend and
the test file are named with measured line numbers.
