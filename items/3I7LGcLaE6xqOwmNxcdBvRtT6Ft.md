## Goal

G2 — the ABI-4 bindings reach cosmic as a pinned toolchain fact: the
cosmos pin advances to the first whilp/cosmopolitan release carrying
wave 1 (#266), so the Teal layer can see `handled_access_net`.

## Change

The release is **`2026.08.21-87869141c`** — the push-triggered build of
`87869141`, which is wave 1's squash-merge (whilp/cosmopolitan#267),
published 2026-08-21T09:47:19Z. It is the first release carrying the
ABI-4 bindings, and it is the target here even though later releases
exist: the ABI 5–9 surface is the sibling bump's (3I7LNDrF), and pins
advance one wave at a time so a red compare gate names which wave
caused it.

Per AGENTS.md's update procedure:

1. `3p/cosmos/cosmos_pin.tl`: `version = "2026.08.21-87869141c"`, and
   the `sha` of that release's `cosmos.zip` asset — download it from
   `https://github.com/whilp/cosmopolitan/releases/download/2026.08.21-87869141c/cosmos.zip`
   and `sha256sum` it; the pin is a two-line literal change.
2. `bin/cosmic --make fetch` (the one verb with a network) lands it;
   `bin/cosmic --make build` regenerates `o/_types/types_gen` from the
   release's embedded `definitions.lua` — the new `unix.landlock_*`
   surface appears in the generated types with no regen step of its own.
3. `o/bin/cosmic --make ci` — fix whatever the new types break (expected
   from wave 1: nothing; the surface is additive).
4. The perf compare gate against the previous pin, per the optimize
   skill's loop — a pin bump is a toolchain change and gets the
   regression check every pin bump gets.

The pin being replaced is `2026.08.15-e21155f87`.

## Non-goals

- no cosmic code changes beyond what a type drift forces — consuming
  the new surface is the R7 net-section slice.
- not the ABI 5–9 release. Bumping straight past `87869141c` to a
  wave-2 release would satisfy this item's presence proof by accident
  and destroy the sibling bump's attribution; the waves land in order.
- never regenerate committed floors to absorb a regression; a red
  compare gate is a finding on the release, not a ratchet chore.

## Acceptance

- `git diff --stat` touches `3p/cosmos/cosmos_pin.tl` (+ any forced type
  fixes) and nothing else.
- `o/bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic -e 'print(require("cosmo").unix.LANDLOCK_ACCESS_NET_CONNECT_TCP)'`
  prints a number, proving the pinned binary carries wave 1.

## Enablement

none needed — AGENTS.md's pin-bump procedure is the whole recipe; this
spec adds only the wave-1 presence proof and the release tag, so the
implementer does not re-derive which release that is.
