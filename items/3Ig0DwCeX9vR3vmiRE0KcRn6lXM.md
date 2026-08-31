# Problem

The board has no way to mark an outcome root held (its win condition
verified) without ending it, and nothing proves the derived order
(transitive closure over `beats` edges, `_work/priority.tl`) stays
total for the OTHER roots once one is held or ended. This item is
board-tooling only: it lands as a direct commit to the `board` orphan
branch, not a PR — `_work/` is gitboard's own source and lives on
`board` itself, so there is no product-repo worktree to build it in
and no separate repo to open a PR against.

# Change

Landing procedure for this item: work in `o/board` (already a
worktree of `board`). Build and test with the board's own
`bin/cosmic --make ci` / `bin/cosmic --make test _work/...` exactly as
any cosmic project is built (per AGENTS.md). When it passes, commit
directly to `board` and push — no PR, no `gitboard verdict`. Close the
item with `gitboard done <id> --reason completed --force --why
'board-tooling change, committed directly to board (no PR to review)'`.

## The mechanism: `is_held`, a marker distinct from `resolution`

An outcome that holds does NOT go through `done`: there is no verb
that reopens a done item today (confirmed — `grep -n reopen
_work/*.tl` finds no verb, and `_work/gitgraph.tl`'s `cmd_set` refuses
outright once `resolution` is non-empty: "a done item's facts are
history, not a repair target"), and the acceptance below requires that
filing new evidence under a held root REOPENS it — trivial for a
marker that never set `resolution`, unbuilt for `done`. Add:

- `_work/item.tl`: a new `is_held: boolean` field on `Item`, in the
  `SPEC` shape (`shape.optional(shape.boolean)` — the primitive
  already exists, see the `draft` example at `cosmic/shape.tl:25`), in
  `Raw`, in `decode`'s `Item` construction, and in `encode` (write
  `t.is_held = true` only when set, omitting the zero value like every
  other field there). Measured headroom: `item.tl` is 479 of 500
  lines (`wc -l _work/item.tl`) — this field costs roughly 5 lines
  spread across the five sites above; stay inside that budget, nothing
  else moves in this file.
- `_work/item.tl`'s `problems(it)`: refuse `is_held` set on a non-root
  (`not is_root(it) and it.is_held`) — holding is an outcome-root
  concept only.

## The verb: `_work/gitcompare.tl` gains `cmd_hold` / `cmd_unhold`

Not a new file, not `_work/gitverbs.tl`: `gitverbs.tl` is 499 of 500
lines (`wc -l _work/gitverbs.tl`) — zero headroom, and `gitcompare.tl`'s
own header already documents why a verb near the cap gets its own
module ("the cap has already caused a defect there once"). `hold`
governs a root's STANDING in the derived order exactly like `compare`
does, so it belongs beside it; `gitcompare.tl` is 103 of 500 lines —
plenty of room. Follow `cmd_compare`'s shape (store read, refusal
checks, `gate.commit_and_publish`, `gate.verdict_line`):

- `cmd_hold(s, id, reason)`: refuses when `id` does not exist, is not
  a root (`item.is_root`), is not open (`item.is_open`), or is already
  held (a no-op refusal, matching `cmd_block`'s pattern). Refuses an
  empty `reason` exactly like `cmd_block` does ("REFUSED: hold records
  why the win condition holds — pass --reason '<...>'"). The reason is
  NOT stored as a field (no room, and no field for it) — it rides only
  in the commit subject (`hold <id8> <reason>`) and the verdict line,
  the same way `compare` records no reason at all and relies on the
  commit log. Sets `it.is_held = true`.
- `cmd_unhold(s, id)`: refuses when not held. Clears `is_held`. This
  is what the reopen rule below calls internally — it is also exposed
  as a verb for a session correcting an erroneous hold without filing
  a throwaway child.

Wire both into `_work/gitboard.tl` (423 of 500 lines, 77 lines of
headroom): the verb-name table (~line 65), a help entry each (mirror
the `compare`/`block` entries around lines 117-120), and a dispatch
branch each (mirror `d.command == "compare"` at line 351) that parses
`ID` (+ `--reason` for `hold`) and calls `gitcompare.cmd_hold` /
`cmd_unhold`.

## The reopen rule: filing evidence under a held root clears it

`_work/gitgate.tl:302`'s `containered(parent)` already returns the
parent item modified (claim/reviewer cleared) so `cmd_new` and
`cmd_attach` in `_work/gitgraph.tl` commit the parent's change in the
SAME commit as the new/adopted child — this is the existing hook for
"the parent just gained a child." Extend it: when `parent.is_held` is
true, also clear it and return the parent even if claim/reviewer were
already empty. `gitgate.tl` is 455 of 500 lines, 45 lines of headroom
— this is a ~3-5 line change to one function plus its doc comment.
Result: `gitboard new "<verification failed after all>" --parent
<held-root-id> --spec-file ...` (or `attach`) un-holds the root in the
one commit that files the child — no separate `unhold` call needed for
this path.

## Derived order stays total: no change to `_work/priority.tl`

`priority.positions(items)` computes `own`/`dominated` by walking
`beats` over EVERY item passed to it — `_work/priority.tl`'s `walk`
(line 91) and `dominated` (line 110) never check `item.is_open` or
`is_held`. Every call site (`_work/gitshow.tl:62`, `_work/gitview.tl:112`,
`_work/gitgraph.tl:244`, `_work/gitcompare.tl:88`, `_work/flow.tl:360,392`)
passes `store.list(s)` unfiltered. So a root's `beats`/beaten edges
keep counting toward every other item's dominance closure whether that
root is open, held, or done — ending or holding a root cannot sever a
chain that placed something else. Do not add filtering here; the
gitgraph test below PROVES this already holds rather than building
anything to make it hold.

## `_work/flow.tl`'s `roots` gains a third return; `_work/intake.tl` skips held roots

`roots(items)` (`_work/flow.tl:358`) today returns `{Item} ordered` (open,
placed roots, priority order) and `{string: boolean} live` (root id ->
has an open item under it). A held root must stay `is_open` (it is
never `done`), so it still appears in `ordered` — `show`/`status`
should still be able to find and render it. What changes is INTAKE's
walk: add a third return, `held: {string: boolean}`, true for root ids
with `it.is_held`. In `_work/intake.tl:69-79`, change the loop
condition from `if not live[g.id] then` to `if not live[g.id] and not
held[g.id] then` — a held root is treated exactly like one with live
work: intake walks past it to the next-ranked root without a hand
edit. `flow.tl` is 465 of 500 lines (35 headroom); `intake.tl` is 103
of 500 (plenty). The only two real callers of `roots` are
`intake.tl:69` and `converge_test.tl:156` (`grep -n
"flow\.roots("`); the test only captures the first return, so the
extra return is source-compatible — nothing else to touch.

# Non-goals

- Ending (`done`) as the held mechanism — rejected above for the
  reopen requirement; do not build a `done`-reopen verb instead.
- Holding anything but a root (`problems` refuses it elsewhere).
- Rendering `is_held` specially in `show`/`status`/`gitview` output —
  useful, but not required by the acceptance below; leave it for a
  follow-up if noticed.
- Any change to `docs/goals.md`, `skills/work/*`, or a decision record
  — those are the cosmic-side child, blocked on this one landing so
  they document what was actually built.

# Acceptance

- `_work/githold_test.tl` (new): `cmd_hold` refuses a non-root, an
  unopened item, an empty reason, and a second hold; the happy path
  sets `is_held` in one commit. `cmd_unhold` refuses when not held and
  clears it in one commit when held.
- `_work/gitgraph_test.tl` (new test, current file 390 of 500 lines —
  110 lines of headroom): file three roots A, B, C; `cmp.cmd_compare`
  A over B and B over C (B carries an edge up AND down, mirroring
  goals.md's G4 today: `[>3]`). Hold B via `gitcompare.cmd_hold`.
  Assert:
  - `prio.is_placed(prio.positions(all), A.id)` and `...C.id)` are
    both still true, and A's `own` count (via `prio.key_of`) is
    unchanged by holding B (still dominates B and C transitively).
  - `flow.roots(all)`'s `ordered` list still contains A and C (a held
    root is not ended, so it is not gone from the general listing).
  - `intake.intake_action(...)` with B held and no live children under
    any of the three never offers B — it returns the next-ranked open
    root, or the "every open root has live work" fallback
    (`_work/intake.tl:83-86`) once every remaining root is held or
    live.
  - Filing a child under B (`graph.cmd_new(s, "...", B.id, nil, "")`)
    clears `is_held` on B in the SAME commit as the new child (one
    commit before and after, per `commits(s)`), and B is no longer
    skipped by `intake_action` afterward (a live child now makes
    `live[B.id]` true regardless).
