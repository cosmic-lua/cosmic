## Goal

G8 — the flow system: the WIP limit exists to force draining, so it must
never refuse the drain itself. Decomposing a plan-phase leaf is net-zero
for plan occupancy; the up-front check counts only the arrival and
refuses it.

## Evidence

2026-08-19, `plan` at 18/12: `gitboard new "cast wave 3…" --parent
3HyArM3A` refused (`REFUSED: plan is at 18/12 — drain it before pulling
more`) although 3HyArM3A was itself a plan-phase leaf whose first child
de-phases it IN THE SAME COMMIT — net zero. The highest-priority
refinement action (decomposing the top epic) was blocked by the limit
that exists to force exactly that refinement; the workaround was filing
refined specs as unparented captures and attaching them later. The same
wall was hit again the same day decomposing the G2 epic.

## Owner decision, 2026-08-19

Admit net-zero decomposition: the up-front check accounts for the
same-mutation de-phase. (Confirmed by the goal owner.)

## Change

Measured 2026-08-19 on the board branch:

1. **`_work/gitverbs.tl`** (431 lines): `cmd_new`'s up-front gate (line
   76, `gate.wip_refusal(flow.board(all), nil, phase)`) runs before the
   parent is examined, yet the same function later de-phases a phased
   parent via `gate.dephased_container` (lines 81–87). Reorder: resolve
   `parent_item` first; when it is phased and its phase equals the
   child's entry phase, the mutation is net-zero — skip the up-front
   refusal (the rebase-path re-check stays, and 3I44Et1Z's arrival
   predicate already makes that half correct once landed). `cmd_attach`
   (line ~140) has the same shape for adopting an unphased capture
   under a phased leaf: same rule.
2. **`_work/gitgate.tl`** (257 lines): rather than special-casing in two
   verbs, give `wip_refusal` the knowledge — an optional
   `vacated: string` parameter (the phase the same mutation empties a
   slot in); when `vacated == to`, the arrival is net-zero and the limit
   has nothing to refuse. Both call sites pass the parent's phase (or
   nil when the parent is unphased/a container).
3. **Tests** (`_work/gitverbs_test.tl`): with a phase at its limit and a
   phased leaf parent, `new --parent` succeeds and the parent leaves the
   phase in the same commit (count unchanged); with a CONTAINER parent
   (no slot vacated) the same call is still refused; `attach` mirrors
   both.

## Non-goals

- no change to the WIP limits' values, to `admits_over_limit`, or to the
  rebase-path re-check (3I44Et1Z owns that half — file-adjacent in
  `gitgate.tl`, so `blocked_by` 3I44Et1Z orders the landing).
- no net-zero credit for anything but decomposition: moves and plain
  arrivals count exactly as today.

## Blocked by

3I44Et1Z (same `gitgate.tl` region, in ready) — mirrored in
`blocked_by`.

## Acceptance

- `bin/cosmic --make test _work/gitverbs_test.tl` ends
  `test: PASS (1 files)`.
- `bin/cosmic --make ci` ends `ci: PASS` on the board worktree.

## Enablement

none needed — the call sites, the de-phase mechanism, and the owner
decision are recorded above; 3I44Et1Z's landing order is carried in
`blocked_by`.
