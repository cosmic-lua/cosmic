## Goal

G8 — the flow system. A mutation that loses the push race is
re-judged by the SAME admission policy the verb applied up front, so
a decision already made is not silently reversed by a rebase.

## Evidence

Re-measured 2026-08-22 at board head `e7cd0c84`.
`gitgate.commit_and_publish`'s post-rebase revalidate re-checks only
the WIP arrival:

```
local limit = flow.LIMITS[it.phase]
local b = flow.board(merged)
if limit ~= nil and #(b[it.phase] or {}) > limit
and flow.is_arrival(from, it.phase)
and not flow.admits_over_limit(from, it.phase) then
```

It reproduces the LIMIT but not the verbs' admission policy, so three
decisions the up-front gate already made are lost when a push loses
its race:

1. **`--force` does not survive.** A forced arrival into a full
   column that loses the race to ANY concurrent commit is refused
   after the rebase — the repair the force authorised silently fails.
2. **`cmd_attach` passes `from = nil` unconditionally**, so
   re-parenting an item that already holds a phase is misclassified
   as an arrival into its own phase and refused after a lost race
   whenever that column is at limit. This is exactly the
   non-arriving-write class #1287 fixed for `spec` and `block`.
3. **The `vacated` credit does not survive.** `cmd_new` gained it in
   #1304 for net-zero decomposition; `from` is nil for an entry, so
   `flow.is_arrival` is true and the merged-state check refuses a
   child whose parent de-phased in the same commit. Newly reachable
   in practice: `plan` is at 48/12 today, so every `new --parent`
   that loses a race hits it.

All three share one root cause and one fix: the revalidate is handed
the limit but not the decision.

## Change

Two files. Keep the signature additive — no call-site sweep.

1. **`_work/gitgate.tl`: `commit_and_publish` gains two optional
   trailing parameters**, `force?: boolean` and `vacated?: string`,
   after the existing `also?: {item.Item}`. Inside the revalidate:
   - when `force` is true, return nil immediately — the force
     authorised this arrival and a rebase does not un-authorise it;
   - pass `vacated` into the limit test the way `gate.wip_refusal`
     already takes it, so a net-zero decomposition is credited after
     the rebase exactly as it was before.

   `wc -l < _work/gitgate.tl` is 346, so there are 154 lines of
   headroom; this adds roughly 15.

2. **`_work/gitverbs.tl`: two call sites.**
   - `cmd_attach` passes the item's ACTUAL phase as `from` instead of
     `nil`, so a re-parent that leaves the item where it stands is
     classified as a non-arriving write and stays editable on a full
     column.
   - `cmd_move`, `cmd_new` and `cmd_done` pass their `force` through;
     `cmd_new` also passes its `vacated` value.

   `wc -l < _work/gitverbs.tl` is 479 — 21 lines of headroom, which
   the roughly 6 lines of extra arguments fit inside. **Do not grow
   this file further**; if a change here needs more than that,
   stop and report rather than restructuring the file.

3. **Tests.** `_work/gitgate_test.tl` (117 lines) already builds the
   lost-race fixture (`init_shared`, `fill_plan_over_limit`) and is
   the right home for all three. Add:
   - `test_force_survives_a_lost_race` — a forced arrival into an
     over-limit column publishes after losing the race.
   - `test_a_reparent_is_not_an_arrival` — a `from` equal to the
     item's phase survives the same race (the #1287 class, now for
     attach).
   - `test_vacated_credit_survives_a_lost_race` — an entry carrying
     `vacated` publishes into an over-limit column after the rebase.

## Non-goals

- **The `block` deadlock race is NOT in scope.** The capture's item
  (3) — two sessions racing reciprocal `block X Y` / `block Y X`,
  landing a cycle because the check runs against the local checkout —
  needs the revalidate to re-ask a graph invariant, not a limit. It
  is a different fix and gets its own item; `status` already reports
  a cycle when one lands.
- **`store.publish`'s leftover commit is NOT in scope.** The
  capture's closing paragraph (a failed publish keeping the local
  commit, and a mid-`save` failure leaving a dirty index) is a
  `_work/store.tl` change, a different file and a different failure.
  Its own item.
- No change to `commit_and_publish`'s existing parameters or their
  order, and no sweep of call sites that do not need the new ones —
  an options-record refactor would touch every verb and is not what
  this fixes.
- No change to `flow.LIMITS`, to `flow.is_arrival`, or to
  `flow.admits_over_limit`.
- No change to any verdict-line format.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitgate_test.tl _work/gitverbs_test.tl`
  ends `test: PASS`, including `test_force_survives_a_lost_race`,
  `test_a_reparent_is_not_an_arrival` and
  `test_vacated_credit_survives_a_lost_race`.
- `wc -l < _work/gitverbs.tl` ≤ 495 and `wc -l < _work/gitgate.tl`
  ≤ 420 — this slice must not consume the little headroom
  `gitverbs.tl` has left.
- `grep -c 'from = nil' _work/gitverbs.tl` is 0 (it is 1 today, in
  `cmd_attach`).

## Enablement

none needed — #1287 is the worked precedent for the whole shape (a
non-arriving write surviving an over-limit rebase), its test lives in
`_work/gitgate_test.tl` beside where these go, and `gate.wip_refusal`
already takes `vacated` so the credit needs no new plumbing of its
own. The wrong turn to predict is refactoring `commit_and_publish` to
an options record: it is the tidier signature and it touches every
verb in the tree, including `gitverbs.tl`, which has 21 lines of
headroom. `Non-goals` forbids it and the `wc -l` bound in Acceptance
is what catches it.
