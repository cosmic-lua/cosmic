> Capture note, 2026-08-19: spec refined to the ready bar; filed unparented because plan and ready sat at their limits. Attach under 3I1IfJ22 (the G2 sandbox epic) and promote when a slot opens; blocked_by edges to record at attach time are in the "Blocked by" section (ids: R1 report = 3I7LBrUN, wave-1 bindings = 3I7LDODd, wave-2 bindings = 3I7LEsGv, pin bump 1 = 3I7LGcLa).

## Goal

G2 — the ABI 5–9 bindings reach cosmic: the cosmos pin advances to the
first release carrying wave 2 (#266), completing the C surface the
facade's final slice builds on.

## Change

Identical procedure to the wave-1 pin bump (its spec is the recipe;
AGENTS.md is the authority): bump `3p/cosmos/cosmos_pin.tl`, fetch,
build (types regen), `o/bin/cosmic --make ci`, perf compare gate. The
presence proof shifts to a wave-2 constant (e.g. a `LANDLOCK_SCOPE_*`
value, exact name per the landed bindings).

## Non-goals

As the wave-1 bump: no cosmic feature code; no floor regeneration to
absorb regressions.

## Blocked by

The wave-2 bindings item and the wave-1 pin bump (pins advance
monotonically) — mirrored in `blocked_by`.

## Acceptance

- `git diff --stat`: the pin (+ forced type fixes) only.
- `o/bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic -e '...'` prints a wave-2 constant non-nil.

## Enablement

none needed — same recipe as the sibling bump.
