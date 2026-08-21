## Goal

G2 — the ABI-4 bindings reach cosmic as a pinned toolchain fact: the
cosmos pin advances to the first whilp/cosmopolitan release carrying
wave 1 (#266), so the Teal layer can see `handled_access_net`.

## Change

Per AGENTS.md's update procedure. The release this bump targets now
exists and is named here rather than left to be looked up:

**`2026.08.21-87869141c`** — the push-triggered release for merge commit
`87869141`, which is wave 1 (#267). Published 2026-08-21T09:47Z.

**Take that release and not a later one.** Wave 2 (#268) merged after it
and will publish its own release; the sibling item 3I7LNDrF owns that
bump, and pins advance monotonically, which is why it carries a
`blocked_by` edge to this one. A bump straight to a wave-2 release would
pass this item's acceptance while leaving its sibling with nothing to
do — so if the pin already names a release at or past
`2026.08.21-87869141c` when this is pulled, that is not a licence to
skip ahead: stop and return the item to `plan` with what was found.

1. `3p/cosmos/cosmos_pin.tl` is a `cosmic.literal` table, not a
   two-line file: set `version` to the tag above and
   `platforms["*"].sha` to the sha256 of that release's `cosmos.zip`
   asset (the `url` field templates `{version}`, so it does not change).
2. **Capture the perf baseline before the pin moves.** Step 5's compare
   gate needs a run under the OUTGOING pin, and bumping first destroys
   it. Per the optimize skill:
   `bin/cosmic --make run _perf/run.tl --out o/perf/base.json`.
3. `bin/cosmic --make fetch` (the one verb with a network) lands the new
   pin; `bin/cosmic --make build` regenerates `o/_types/types_gen` from
   the release's embedded `definitions.lua` — the new `unix.landlock_*`
   surface appears in the generated types with no regen step of its own.
4. `o/bin/cosmic --make ci` — fix whatever the new types break (expected
   from wave 1: nothing; the surface is additive).
5. The perf compare gate against the baseline from step 2, per the
   optimize skill's loop — a pin bump is a toolchain change and gets the
   regression check every pin bump gets.

## Non-goals

- no cosmic code changes beyond what a type drift forces — consuming
  the new surface is the R7 net-section slice.
- never regenerate committed floors to absorb a regression; a red
  compare gate is a finding on the release, not a ratchet chore.
- do not fold the sibling wave-2 bump (3I7LNDrF) into this one.

## Blocked by

The wave-1 bindings item — merged 2026-08-21 as whilp/cosmopolitan#267,
so this edge no longer binds.

## Acceptance

- `git diff --stat` touches `3p/cosmos/cosmos_pin.tl` (+ any forced type
  fixes) and nothing else.
- `3p/cosmos/cosmos_pin.tl` names version `2026.08.21-87869141c`.
- `o/bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic -e 'print(require("cosmo.unix").LANDLOCK_ACCESS_NET_CONNECT_TCP)'`
  prints `2`, proving the pinned binary carries wave 1. (The module is
  `require("cosmo.unix")` — `require("cosmo").unix` is nil, and an
  unknown field under `-e` prints `nil` rather than failing, so read the
  value and not the exit status. Both were checked against the current
  pin on 2026-08-21, where this command prints `nil` because the pin
  predates wave 1 — which is the before-state this bump changes.)
- `o/bin/cosmic -e 'print(require("cosmo.unix").LANDLOCK_SCOPE_SIGNAL)'`
  prints `nil`, proving this is the wave-1 release and not a later one —
  the sibling bump is what makes that constant appear.
- `o/_types/types_gen/cosmo/unix.d.tl` declares `landlock_create_ruleset`
  with a `handled_access_net` parameter and declares
  `landlock_add_net_rule` — the Teal-layer half of the Goal, which the
  constant alone does not show.
- The compare gate's verdict quoted in the PR description.

## Enablement

none needed at the core/docs/skills level — AGENTS.md's pin-bump
procedure is the whole recipe, and both wrong turns predicted for this
slice are facts about this bump rather than mechanizable rules: which
release to take, and that the perf baseline must be captured before the
pin moves. Both are now closed in the `Change` steps and re-checked by
the `Acceptance` commands, the second of which fails loudly if the wrong
release was taken.
