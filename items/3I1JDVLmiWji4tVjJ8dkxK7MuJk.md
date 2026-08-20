Imported from whilp/cosmic#1225.

## Goal

G9 — the least tree that keeps its promises, via the ratchet-unification epic
(#1221). This is the slice that pays back the friction the epic was filed
from: a ratchet that fails without naming its regen command costs a session a
decision detour.

Blocked by: #1223, #1224

## Change

One regen verb and one failure contract, written once over three gates that
by now share a reader.

- Add `bin/cosmic --make baseline [NAME]` in `_make/`: with no argument it
  regenerates every committed floor; with a name (`coverage`, `casts`,
  `surface`) just that one. `--make coverage --baseline` keeps working as an
  alias for the coverage case — CLAUDE.md and CI both name it.
- Every ratchet failure, in BOTH directions, ends with the exact command that
  regenerates its floor, and says what a legitimate justification is when the
  move is an increase. Today only `_build/casts_test.tl`'s DECREASE branch does
  (`REBASELINE`, line 26); its increase branch says "remove them, or justify
  the increase in the PR" and names no command.
- One failure shape across the three gates, so a session that has read one has
  read all three.
- Update CLAUDE.md's testing section and `skills/work/decompose.md`'s ratchet
  clause — it already tells a slice to "run exactly the regen command the
  gate's failure message prints", and this makes that instruction true for
  every gate in both directions.

## Non-goals

No change to what any gate measures, to any tolerance, or to any floor's
values. No new ratchets. `--make baseline` regenerates and never checks — the
gates keep that job, and a verb that did both would invite regenerating inside
CI. No change to the `ci: PASS` / `ci: FAIL` verdict line format.

## Acceptance

Sketch — replace with measured commands at refinement.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make baseline` regenerates all three floors and leaves an
  unchanged tree byte-identical.
- Each gate's failure message is asserted by its own test, in both directions,
  to contain the regen command.
- `bin/cosmic --make help` lists `baseline`.

## Enablement

Blocked by #1223 and #1224 — the contract is written once, over migrated gates,
rather than three times over three designs.

## Refinement pass, 2026-08-20

Still blocked: `3I1J9Xhg` (#1224, the coverage-floor-to-literal slice) is
implemented and in review (PR #1295, not yet merged) — this item stays in
`plan` until it lands, per its own `blocked_by`. What this pass measured,
against the tree at `bce1971e` (PR #1295's head):

- **`_make/init.tl` is 498 lines — only 2 lines of headroom under the
  500-line cap** (`wc -l < _make/init.tl`). This is the load-bearing fact
  for `Change`'s first bullet: the new `baseline [NAME]` verb's dispatch
  logic (name → one of three regen paths, no name → all three) CANNOT be
  written inline in `_make/init.tl`'s `VERBS` table as the sketch implied —
  there is no room. It has to live in a new `_make/baseline.tl`, with
  `_make/init.tl` gaining only a `{name = "baseline", run = baseline.run}`
  registry entry (one line, matching every other verb's registration
  style) plus a `local baseline = require("_make.baseline")` import line.
- **Neither `_build/casts.tl` nor `_build/public_surface.tl` exports a
  reusable regen function today** — each has only a `main(...)` CLI entry
  (`proc.is_main()`-gated) that parses `--baseline` itself and calls
  `floor.write` inline (`_build/casts.tl:112-134`,
  `_build/public_surface.tl:109-130`). The new verb needs each to export a
  plain `write_baseline(): boolean, string`-shaped function (mirroring
  `_tool.coverage.baseline.text_for` + `_make.policy.write_baseline`'s
  split) that both `main()` and the new verb call, rather than the verb
  shelling out to `bin/cosmic --make run _build/casts.tl --baseline` as a
  subprocess.
- **The three failure-message shapes, measured exactly** (at `bce1971e`):
  - `_build/casts_test.tl`'s DECREASE branch already names the regen
    command via its `REBASELINE` constant (line 25); its INCREASE branch
    (line 32-34) says `"%s: %d casts (baseline %d) — remove them, or
    justify the increase in the PR"` — no command named. This is the one
    real gap `Change`'s second bullet describes.
  - `_build/public_surface_test.tl` already names its `REGEN` constant in
    BOTH directions (`added`, line 33; `gone`, line 39) — this file is
    already at the target shape and is the one the other two should match,
    not a third design to invent.
  - `_tool/coverage/baseline.tl`'s per-row messages (`compare()`, the
    per-file and total decline lines) do NOT name the regen command; only
    the aggregate summary `check()` prints once, at the end, does
    (`"coverage ratchet: %d problem(s); if the decline is intended, run
    'cosmic --make coverage --baseline' and commit the result"`). Whether
    the unified contract belongs on every per-row line (matching
    casts/surface) or stays as one aggregate line (coverage's existing,
    arguably more readable, shape given it can report many rows at once)
    is the one real design decision this item still has open — a plan
    session must pick one and state it in `Change`, not leave both shapes
    coexisting as "one contract."
- **`_tool/coverage/baseline_test.tl` is AT its 500-line cap** (PR #1295
  lands it there exactly). This item's own Acceptance line — "each gate's
  failure message is asserted by its own test, in both directions" —
  therefore has ZERO headroom to add a new coverage-side test once #1295
  merges. The refinement that moves this item to `ready` must either
  extend an existing coverage test (e.g. fold the regen-command assertion
  into `test_a_failing_ratchet_names_the_rows_that_moved`, which already
  captures a real failing run's stderr) or name a file split as part of
  `Change` — leaving it as a bare Acceptance line with nowhere to put the
  test it demands is exactly the "acceptance by vibes" this item must not
  ship.

Next refinement pass, once `3I1J9Xhg`/#1295 lands: unblock, settle the
per-row-vs-aggregate design question above, write concrete Acceptance
commands (replacing the sketch) naming `_make/baseline.tl`'s measured
headroom and the exact new/extended test per gate, then `move ID ready`.


---
_Generated by [Claude Code](https://claude.ai/code)_