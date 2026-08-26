## Goal

G6 — the defining paths, ratcheted. The cosmic half of the parent
container's one-pass fix: once `cosmo.EncodeLua` refuses the literal
reader's domain itself, delete the Teal pre-walk that duplicates it.

## Evidence

Measured 2026-08-26 at cosmic main `14ff1d1d`, with `o/bin/cosmic`
built from the tree.

- `format_compact` costs 2.58x the `cosmo.EncodeLua` call it wraps
  (332 KB fixture: 14.52 ms against 5.64 ms), and 61% of that is the
  walk (8.89 ms). The parent item carries the harness and both tables.
- The code to delete: `is_compact_writable`
  (`cosmic/_literal_format.tl:339-362`), and — only if nothing else
  calls them — `is_compact_string` (`:61-63`) and `is_compact_scalar`
  (`:81-92`). Enumerate the callers at refinement (`grep -n` each
  name in that file); `is_finite` (`:46-48`) is also used by the
  non-compact renderer at `:113`, so it stays.
- The behaviour to preserve: a value outside the domain falls back to
  the pin layout via `return format(value)` (`:397-399`). With the C
  refusal, the fallback moves AFTER the encode attempt rather than
  before it — the refusal is what triggers it.
- `_literal_format_test.tl` pins the refusal set; the parent's
  Acceptance names it as the fidelity bar.
- The regression gate is `_perf`'s `literal_format_floor_compact`
  scenario (`_perf/bench/literal_bench.tl`), landed in #1400 for this
  hypothesis. Note it runs a 100-row `FLOOR` fixture, far smaller than
  the payloads above: the win shows as a ratio, not a large absolute
  number on that row.

## Change

Sketch, to be made exact at refinement once the sibling's option name
and `reason` strings are fixed:

1. `3p/cosmos/cosmos_pin.tl` — bump to the release carrying the
   sibling's change.
2. `cosmic/_literal_format.tl` — `format_compact` calls
   `cosmo.EncodeLua(value, {sorted = true, <option> = true})` and, on
   a refusal, returns `format(value)`; the walk and its now-unused
   predicates go.
3. `_types` regenerates from the new `definitions.lua` as a
   consequence of the build — no regen step, per AGENTS.md.

## Non-goals

- No change to the refusal SET. Every value the walk turns down today
  must still take the pin-layout handoff, and
  `_literal_format_test.tl` is where that is pinned. If the C option
  refuses a value the walk admitted, or admits one it refused, this
  slice stops and the sibling is fixed — cosmic does not paper over
  the difference with a residual Teal check.
- No change to `format`, `format_file`, or the pin layout.
- No change to the `cosmo.*` C boundary from this side: this slice
  consumes the contract, it does not move it.
- No unrelated micro-optimization of the module (see the parent's
  ruled-out option (b) — do not land any part of it here).

## Acceptance

To be written at refinement. At minimum: `bin/cosmic --make ci` ending
`ci: PASS`; `bin/cosmic --make test cosmic/_literal_format_test.tl`
passing unchanged; and the `optimize` skill's compare gate over
`literal_format_floor_compact` showing an improvement rather than a
regression.

## Enablement

Blocked on the whilp/cosmopolitan slice, which must land and be
released before this one can bump a pin at it.
