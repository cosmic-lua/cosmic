## Goal

G2 — the ABI-4 bindings reach cosmic as a pinned toolchain fact: the
cosmos pin advances to the first whilp/cosmopolitan release carrying
wave 1 (#266), so the Teal layer can see `handled_access_net`.

## Change

Per AGENTS.md's update procedure, once the wave-1 PR merges and the
push-triggered release publishes (tag `YYYY.MM.DD-<short-sha>` — the
cross-repo edge is that releases page, read by whoever pulls this):

1. `3p/cosmos/cosmos_pin.tl`: new version + sha256 (two-line literal).
2. `bin/cosmic --make fetch` (the one verb with a network) lands it;
   `bin/cosmic --make build` regenerates `o/_types/types_gen` from the
   release's embedded `definitions.lua` — the new `unix.landlock_*`
   surface appears in the generated types with no regen step of its own.
3. `o/bin/cosmic --make ci` — fix whatever the new types break (expected
   from wave 1: nothing; the surface is additive).
4. The perf compare gate against the previous pin, per the optimize
   skill's loop — a pin bump is a toolchain change and gets the
   regression check every pin bump gets.

## Non-goals

- no cosmic code changes beyond what a type drift forces — consuming
  the new surface is the R7 net-section slice.
- never regenerate committed floors to absorb a regression; a red
  compare gate is a finding on the release, not a ratchet chore.

## Blocked by

The wave-1 bindings item — mirrored in `blocked_by`. (The release
between them is the URL edge: whilp/cosmopolitan's releases page.)

## Acceptance

- `git diff --stat` touches `3p/cosmos/cosmos_pin.tl` (+ any forced type
  fixes) and nothing else.
- `o/bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic -e 'print(require("cosmo").unix.LANDLOCK_ACCESS_NET_CONNECT_TCP)'`
  prints a number, proving the pinned binary carries wave 1.

## Enablement

none needed — AGENTS.md's pin-bump procedure is the whole recipe; this
spec adds only the wave-1 presence proof.
