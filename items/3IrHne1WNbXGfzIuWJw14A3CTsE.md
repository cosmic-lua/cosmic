# friction: 2026-09-04 work9 (/work 9 --routine)

## orchestrator
- goal: open the friction log before the first board verb, per
  `skills/work/friction.md` step 1.
  actually happened: ran `sync`, `show`, `next`, and three `take` calls
  before creating this file — the same miss «FcWz_FClp» (an earlier
  pass, same date) already recorded.
  contributed: the ordering rule lives only in `friction.md`'s "the
  log" section, not restated where `SKILL.md`'s `--routine` step list
  is actually read mid-pass; «FcWz_FClp» named this exact fix as an
  unfiled candidate.
  improvement: filed as «VIU8_B2az» (this pass, under «FcWz_FClp») —
  a doc sentence adding the concrete verb-ordering constraint to
  `SKILL.md` itself.
- goal: fill a 9-wide wave with disjoint band-1 builds.
  actually happened: of ~8 open band-1 items, only 3 (rNh1_b1Se,
  HKdD_OAYN, wPWu_rhZQ) were file-disjoint from each other; every other
  pullable band-1 item touches `_work/brief.tl` or `_work/brieftext.tl`
  (confirmed by reading 7 full specs' `## Change` sections by hand —
  7 `show` calls). One further item, «sWmK_pFNW», was fully specced
  but unplaced (root, no priority) — a `show`-then-`attach` round
  surfaced it as a 4th disjoint build. Final wave: 4, not 9.
  contributed: exactly the collision «HKdD_OAYN» itself is building a
  fix for (no cross-reference between open specs' `## Change` sections);
  separately, `next`'s board-wide `show` listing is not priority-sorted
  and mixes unpullable low-band items in with band-1 ones, costing one
  extra `show` per candidate to confirm state/bar before trusting it.
  improvement: none beyond «HKdD_OAYN» itself, already in flight; a
  smaller wave than N here is the collision doctrine working as
  designed, not a gap.
- goal: `attach` an unplaced root («sWmK_pFNW») into the priority
  order so it becomes a pullable build.
  actually happened: `attach` set no `base`; the item's own Change
  section names `_work/gitview.tl` (board-branch-only — confirmed
  `git show main:_work/gitview.tl` fails, exists on `board`), but
  `gitboard brief builder` defaulted the branch to `origin/main`,
  which would have handed a builder a worktree with no `_work/`
  directory at all. Caught before spawn by reading the emitted
  brief's "branched off the latest `origin/<X>`" line; fixed with
  `gitboard set sWmK_pFNW --base board`.
  contributed: `attach` (unlike `new --repo`) does not ask for or
  infer `base` from the parent/sibling items it is placed among, even
  though every sibling under the same parent already carries
  `base: board`.
  improvement: `attach` could default an item's unset `base` (and
  `repo`) from its new parent's own value when the parent has one, or
  `gitboard brief` could refuse to emit a brief for a `board`-only-path
  Change section against a non-`board` base. Not filed — needs a look
  at whether "infer scope from Change paths" is reliable enough to
  gate on, versus just defaulting from the parent; stays here for
  triage.

## candidates
- `SKILL.md`'s `--routine` step list restating the friction-log-first
  verb-ordering constraint, instead of leaving it only in
  `friction.md` — filed as «VIU8_B2az» (parent «FcWz_FClp»).
- `attach` defaulting an unset `base`/`repo` from the new parent's own
  value (or `gitboard brief` refusing a brief whose Change paths don't
  exist on the resolved base) — not filed: two different fixes would
  both work and this pass didn't have time to pick and spec one over
  the other; stays here for triage.
