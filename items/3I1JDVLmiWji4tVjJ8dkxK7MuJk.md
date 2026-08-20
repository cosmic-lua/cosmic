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

## Refinement pass, 2026-08-20 #2 (settles the per-row-vs-aggregate design and the coverage-test cap; item stays blocked on #1295)

Item stays in `plan` — still blocked by `3I1J9Xhg`/#1295, which is in
`check` with a `request changes` verdict (its rework is not this session's
work). This pass does not attempt to move to `ready`; it resolves the two
decisions the first pass left OPEN so the next refinement pass — after
#1295 lands — has only Acceptance commands to write.

9. **Per-row-vs-aggregate — SETTLED as PER-ROW.** Every failure line, in
   every gate, in both directions, ends with the exact regen command;
   coverage's aggregate summary line at `_tool/coverage/baseline.tl:288`
   is REMOVED once per-row lines all carry the command (otherwise it
   would repeat what every line above already said). Three reasons:

   1. **Per-row is already the local convention in coverage.** Four of
      coverage's failure paths already name the command per row:
      not-in-baseline (`baseline.tl:217`), stale-baseline-entry
      (`baseline.tl:235`), duplicate-row (`baseline.tl:277`), and the
      empty-baseline case (`baseline.tl:323`). Only the two `compare()`
      decline paths (`baseline.tl:224-227` per-file and
      `baseline.tl:244-246` total) are the outliers. Bringing the
      outliers into line is one small edit; moving the four existing
      per-row lines to aggregate-only would delete information (a
      not-in-baseline row and a decline row have different remedies,
      even though both share the same regen command).
   2. **Matches the shape casts/surface already share.** Both
      `_build/casts_test.tl` (with `REBASELINE`) and
      `_build/public_surface_test.tl` (with `REGEN`) already have one
      constant per file, suffixed onto every failure branch. Coverage
      adopting the same shape means the three test files carry one
      pattern between them, which is exactly what the epic's "one
      contract, one shape" clause asks for.
   3. **A session grepping stderr for a fix sees it at the failing
      line.** With aggregate-only, a decline line reads `"lib/a.tl:
      coverage declined 80.0% -> 70.0% (70/100, baseline 80/100)"`
      with no fix mentioned; a session then has to scroll to the tail
      to find the command. Per-row eliminates the scroll — a single
      grep for `lib/a.tl` returns the fix beside the fault.

   The concrete change to `_tool/coverage/baseline.tl`:
   - `compare()` at line 225 and line 244 gains a shared suffix
     constant `REGEN_HINT = " — if the decline is intended, run
     'cosmic --make coverage --baseline' and commit the result"`
     appended to both format strings.
   - `check()` at lines 285-291 drops the aggregate line entirely; the
     "if the decline is intended..." text is now on every per-row
     failure, and printing a summary count without the text would just
     be a count of already-printed lines. This is a strict reduction —
     no message text is lost, only duplicated text is dropped.

10. **The coverage-side test cap — SETTLED as EXTEND, not split.** After
    #1295 lands (bringing `_tool/coverage/baseline_test.tl` to its 500
    cap), the two decline-branch tests already in the file get one added
    assertion each — no new test function, no file split:
    - `test_fails_on_file_decline_beyond_tolerance` (currently
      `_tool/coverage/baseline_test.tl:73`) already produces the
      per-file decline message via `violations()`; add one assertion
      that the message contains `"cosmic --make coverage --baseline"`.
    - `test_total_ratchet_catches_masked_decline` (currently line 110)
      already produces the total-decline message; same one added
      assertion.

    Both assertions are one line each — headroom cost: 2 lines against
    the 500 cap #1295 lands the file at. `test_a_failing_ratchet_names_the_rows_that_moved`
    named by the FIRST refinement pass does not exist in the file (the
    prior refinement pass misnamed the test); the two tests above are
    the actual sites.

    **The removed aggregate summary line at `baseline.tl:285-291` is
    not asserted by any existing test in `baseline_test.tl` at
    `bce1971e`** (`grep -n "problem(s)" _tool/coverage/baseline_test.tl`
    is empty), so deleting it costs no test edit beyond the two above.

## Still open (next pass — after #1295 lands)

- Rewrite Acceptance's four bullets as measured commands with verdict
  lines quoted verbatim, per AGENTS.md's "read the verdict line"
  discipline; the sketch stays as it is until `_make/baseline.tl`
  actually exists to run against.
- Verify `_make/init.tl`'s 498-line count still stands at #1295's
  merged state — if #1295's landing pushes it over, `_make/baseline.tl`
  needs to absorb a second line of registration overflow rather than
  the one this pass planned for.
- Confirm the two coverage-side test line counts (73 and 110 today) at
  the merged state, in case rebasing shifts them; the test NAMES are
  the load-bearing selector, not the line numbers.

## Enablement

STILL BLOCKED on #1295 landing. Refinement passes 1 and 2 have between
them measured every fact this item's Change and Non-goals rest on and
settled every design decision; the next pass has only Acceptance
commands to write once the blocker unblocks.
