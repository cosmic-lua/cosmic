Imported from whilp/cosmic#1224.

## Goal

G9 — the least tree that keeps its promises, via the ratchet-unification epic
(#1221). This is the slice that deletes the second parser.

Blocked by: #1222

## Change

Convert `.cosmic-coverage` to the `cosmic.literal` format and make
`_tool/coverage/baseline.tl` read and write it through `_tool/floor.tl`,
deleting its own line scan, its `path covered total` split, its repeated-path
resolution and its canonical write.

- The floor becomes one `["path"] = { ["covered"] = C, ["total"] = T },` per
  line, sorted by path — the inline-nested-table layout `3I7BQPsM` adds to
  `cosmic.literal.format`, the same shape and sort the other two floors have,
  and a `cosmic --check fmt` fixpoint like them.
- The repeated-path rule survives unchanged in meaning: the lower percentage
  wins, expressed now as the `worse` resolver the helper passes to
  `on_duplicate`. Its comment in `.gitattributes` stays true and should be
  updated to name the mechanism rather than the hand-rolled parser.
- What stays coverage's own: the tolerances (`total_tolerance_pp`,
  `file_tolerance_pp`), the file-set drift check, and `lowered`'s rule that a
  rewrite lowers only the rows this run would have failed on. Those are
  judgment, and judgment stays in the gate.
- The conversion of the committed file itself is part of this diff: the same
  rows, the same numbers, a different encoding. State the row count before and
  after as a fact, and show that no row's numbers moved.

## Non-goals

No change to the tolerances, to the ratio semantics, or to any row's numbers —
a coverage percentage that moves in this PR is a bug. No change to
`--make coverage`'s flags or its output lines. No change to `merge=union` on
the floor; only the comment above it. The failure-message contract is #C4.

## Acceptance

Measured 2026-08-20 at `c935338a` (re-measured this pass, unchanged since the
prior pass): `.cosmic-coverage` is 251 lines — 249 data rows, 2 comment
lines, 0 duplicate paths (`grep -vc '^#' .cosmic-coverage` is 249; `wc -l <
.cosmic-coverage` is 251; `grep -v '^#' .cosmic-coverage | awk '{print $1}' |
sort | uniq -d | wc -l` is 0). `_tool/coverage/baseline.tl` is 424 lines (76
of headroom under the 500-line cap) and `_tool/coverage/baseline_test.tl` is
484 lines (16 of headroom) — the parser tests this slice deletes are what
makes room for the new ones. `grep -c "gmatch\|line:match"
_tool/coverage/baseline.tl` is 3 (the hand-rolled scan this slice deletes).

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make coverage --baseline` on an unchanged tree leaves
  `.cosmic-coverage` byte-identical to what this PR commits (`git diff
  --stat -- .cosmic-coverage` empty after re-running it).
- `bin/cosmic --make test _tool/coverage/baseline_test.tl` ends `test: PASS
  (1 files)`, including a `test_migration_preserves_every_row` that parses
  the pre-conversion baseline text (a fixture: `git show c935338a:.cosmic-coverage`,
  captured into `testdata/` at implementation time) with the OLD line-scan
  logic reproduced in the test itself (not the deleted production code —
  the deletion is the point), parses the converted `.cosmic-coverage` with
  `_tool.floor.read`, and asserts the two produce the same 249
  `{path: {covered, total}}` pairs, none moved.
- `git grep -c "gmatch\|line:match" -- _tool/coverage/baseline.tl` is 0
  (today: `grep -c 'gmatch\|line:match' _tool/coverage/baseline.tl` is 3 —
  the deleted hand-rolled scan).
- `.gitattributes` line 9 (`.cosmic-coverage merge=union`)'s neighboring
  comment, if it names the hand-rolled parser, is reworded to name
  `cosmic.literal`/`_tool.floor` instead — checked by eye, not a command.

## Enablement

none needed — `3I7BQPsM` (`cosmic.literal.format`'s inline-row layout) has
LANDED (PR #1293, accepted, merged at `bfa71210`) and `blocked_by` is now
empty. Verified this pass (2026-08-20, against the built tree at `c935338a`):
`literal.format({["a.tl"] = {covered = 47, total = 65}})` now renders
`["a.tl"] = {["covered"] = 47, ["total"] = 65}` on one line, and
`literal.parse` round-trips it back to the same table — exactly the layout
this slice's `Change` depends on, confirmed working rather than assumed.

## Refinement finding, 2026-08-19 (measured, blocks the ready bar)

The row shape this spec states — one `["path"] = {covered, total},` per
line — is outside `cosmic.literal`'s grammar, in both directions.
Measured against a built worktree at `f420391`:

```
$ o/bin/cosmic -e '... literal.format({["a.tl"] = {47, 65}}) ...'
a.tl.1: a number is not a string key
$ o/bin/cosmic -e '... literal.parse("return {[\"a.tl\"] = {47, 65}}") ...'
parse refused: a literal is a table of `name = <literal>` entries; found '47'
```

Named fields (`{ ["covered"] = 47, ["total"] = 65 }`) parse and format
fine, but `literal.format` lays every nested table out MULTI-LINE (one
line per field plus braces), and one-line rows are load-bearing here:
`.gitattributes` gives `.cosmic-coverage` `merge=union`, which only
merges cleanly when a row is a line.

Settled encoding: rows become
`["path"] = { ["covered"] = C, ["total"] = T },` — named fields, ONE
line per row. That is whitespace-only relative to what `parse` already
accepts, so it needs no grammar change — only a layout rule in
`cosmic.literal.format`: a nested table whose values are all scalars
formats inline. No committed floor changes bytes under that rule today
(`_build/casts_baseline.tl` and the public-surface floor hold only
scalar values; measured: `grep -c '= {' _build/casts_baseline.tl` is 0).

That layout rule is an enablement slice on `cosmic.literal` (public
module, additive formatter behavior), filed as its own capture on the
board — this item is blocked on it, mirrored in `blocked_by`, and stays
in `plan` until it lands. The current floor, re-measured: 245 data rows,
2 comment lines, no duplicate paths. `_tool/coverage/baseline_test.tl`
is 484 lines — 16 under the cap — so the parser-test deletion this slice
performs is also what makes room for any new row-shape tests.

## Refinement pass, 2026-08-20

`3I7BQPsM` (the blocker) has not landed yet — this item stays in `plan`,
still blocked. What this pass did: replaced the `Acceptance` sketch with
measured commands (row counts re-measured at `9c3f5325`: 249 data rows,
up from 245 on 2026-08-19 — the tree has grown four rows since, including
this session's own `_fuzz/shrink.tl` coverage entry), added a concrete
migration-preserves-every-row test shape, and a mechanical grep proving
the hand-rolled scan (`gmatch`/`line:match`, 3 matches today) is gone
post-conversion. No change to `Goal`, `Change`, or `Non-goals` — those
already held up under this reading. Next refinement pass, once `3I7BQPsM`
lands: re-verify the row-count/headroom numbers haven't drifted further,
then `move ID ready`.

## Refinement pass, 2026-08-20 (later)

`3I7BQPsM` landed (PR #1293, merged). Unblocked (`gitboard unblock 3I1J9Xhg
3I7BQPsM`) and re-measured against the current tree at `c935338a`: every
number in this pass's `Acceptance` section is unchanged from the prior
pass (249 data rows, 251 total lines, 0 duplicates, `baseline.tl` 424 lines,
`baseline_test.tl` 484 lines, 3 `gmatch`/`line:match` matches) — no drift
since 2026-08-20's earlier pass. Confirmed the enabler actually delivers
the layout this spec's `Change` assumes (see `Enablement` above, verified
by spike rather than by reading `3I7BQPsM`'s own claim). This item now
clears the ready bar and moves to `ready`.
