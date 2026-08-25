## Goal
G3 — an honest type layer. The parent is "casts: close the 55 any-map
field walk from-any sites"; this is its tl-syntax-tree slice: 6 of those
sites, all in `_tool/coverage/lines.tl`.

## Change
Declare the tl syntax-tree fields the coverage walker reads as a record
LOCAL to `_tool/coverage/lines.tl`, and index it as a record. One file
plus one baseline row; no other file moves.

**1. Add the record** directly after `local tl = require("tl")` (line 8):

```teal
--- The tl syntax-tree fields this walker reads.
--- A narrow view of tl's own AST node: `tl.parse_program` returns it as
--- `any`, and the fields below are the only ones a line walk touches.
local record Node
  kind: string
  y: integer
  exp: Node
  exps: Node
  if_blocks: {Node}
end
```

**2. Retype `mark_statement`** (today `_tool/coverage/lines.tl:28`): its
first parameter becomes `Node` instead of `{any: any}`, its `@param`
tag becomes `@param node Node`, and every bracketed read becomes a
field read — `node.kind`, `node.y`, `node.exps`, `node.exp`,
`node.if_blocks`, `exp.y`, `block.exp`, `block.y`. All six
`-- cast: from any` comments in this function go with the casts they
justified. The branch structure, `exec_kinds`, the comments explaining
why `repeat`/`if`/function definitions are handled as they are, and the
`if not kind or not y then return end` guard all stay exactly as they
are.

**3. Narrow with `Node` at the one call site.** In `walk`, the
statements-child guard `if child is {any: any} then` becomes
`if child is Node then`. Both compile to the same test — verified on
this tree, `grep -n 'type(child)' o/_tool/coverage/lines.lua` prints
`if type(child) == "table" then` before and after — so `mark_statement`
takes a `Node` with no cast at the boundary and the walk's behaviour is
byte-identical.

**4. Leave `walk` and `executable_lines` alone.** `walk` keeps its
`{any: any}` parameter and its two `-- cast: array view of ast map`
casts (`:75`, `:87`), and `executable_lines` keeps the
`-- cast: ast node as generic map` at `walk(ast as {any: any}, ...)`
(`:122`). The recursive traversal visits every field of an arbitrary
node, including fields this record deliberately does not name; a record
cannot express that, so those three casts are correctly reasoned and
stay. Only the six `from any` casts close.

**5. Regen the cast floor.** `bin/cosmic --make run _build/casts.tl
--baseline`, then commit `_build/casts_baseline.tl`. That is the exact
command the gate's failure message prints; no gate is weakened any other
way.

**Measured 2026-08-25 against `1f9279ab`**, each with the command that
produced it, and each re-measured with the change applied:

| command | today | after |
| --- | --- | --- |
| `grep -c -- "-- cast: " _tool/coverage/lines.tl` | 9 | 3 |
| `grep -c -- "-- cast: .*from any" _tool/coverage/lines.tl` | 6 | 0 |
| `wc -l < _tool/coverage/lines.tl` | 134 | 145 |
| `grep -n '"_tool/coverage/lines.tl"' _build/casts_baseline.tl` | `= 9` | `= 3` |

145 lines leaves 355 of headroom under the 500-line cap, so placing the
record in this file is not a capacity question.

**Why hand-declared, and not generated from the pin.** This was the
item's open decision; it is settled, and the generated route is not
available. Measured against the pinned tl (`o/3p/tl/tl.tl`, v0.24.8,
after `bin/cosmic --make fetch`):

- `_types/gentl.tl`'s `verify_record` looks for `"\n%s+record <Name>\n"`
  — an INDENTED declaration inside `record tl`. tl declares its AST node
  as `local record Node` at column 0: `grep -n "^local record Node$"
  o/3p/tl/tl.tl` prints `2201:local record Node`. The pattern cannot
  match it. The only indented `Node` inside `record tl` is an empty
  abstract `interface Node end`: `grep -n "^   interface Node$"
  o/3p/tl/tl.tl` prints `674`.
- Even found, a curated field subset naming `y` would fail
  verification: `Node` gets `y`/`x` from `is {Node}, tl.Node, Where`,
  not from its own body, and `verify_record` matches field names inside
  the body only.
- `tl.d.tl` is the PUBLIC tl surface the artifact ships as the types
  user scripts see for `require("tl")`. Widening it with tl's internal
  AST — 60+ fields that move at every pin bump — to serve one internal
  `_tool/` walker is a cost `_tool/**` has no business imposing.

`cosmic/_teal_ast.tl`, named as a candidate when this item was filed, is
not one: it thaws the pre-parsed stdlib AST cache for `tl.new_env` and
declares no node shape. It is unrelated to this slice.

**Public surface.** `_tool/**` never ships in a user artifact and
`_build/public_surface_baseline.tl` is keyed by `cosmic.*` module name
only — `grep -c "_tool" _build/public_surface_baseline.tl` prints `0`.
This slice moves no public surface.

## Non-goals
- **The coverage line-mapping behaviour is frozen.** `walk`'s
  traversal, `exec_kinds`, and every `mark_statement` branch keep their
  current behaviour; only the TYPES move. `.cosmic-coverage` must not
  move, and it does not: with this change applied on this tree,
  `o/bin/cosmic --make coverage` ran 239 checks and printed
  `coverage ratchet ok` / `coverage: PASS (239 files)` with no edit to
  the committed floor. If it moves in your diff, the walk changed and
  the diff is wrong — do not regenerate the floor to make it pass.
- **Do not touch `_types/gentl.tl`** — not its erasure rules, not
  `RECORD_FIELDS`, not `PRELUDE`, not `KEEP`/`TO_STRING`/`NAMED`. The
  generated `tl.d.tl` surface does not move.
- **No tl pin bump.** `3p/tl/tl_pin.tl` stays at v0.24.8.
- **Do not widen `walk` to take `Node`,** and do not remove the three
  remaining casts at `:75`, `:87` and `:122`. Closing those needs a
  different mechanism and is not this slice.
- **Do not edit `docs/design/casts.md`.** Its tables are a snapshot
  dated `d3e59de7` and are already stale independently of this slice:
  measured 2026-08-25 against `1f9279ab`, 5 of the 13 rows in its
  "Any-map field walk" table name files that are gone or now carry zero
  from-any sites, the live rows sum to 22 against a stated total of 55,
  and the document's headline `192 of the 402` measures 111 of 314
  today (`git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l`,
  and the same piped through `grep -c "from any"`). Editing one row
  leaves the document neither current nor a coherent snapshot, and every
  sibling slice under this parent would collide on the same table.
  Refreshing it is its own item, filed as `3IQC4GeO`.
- **No change to any other file.** Not `_tool/coverage/report.tl`, not
  `baseline.tl`, and no test file: `_tool/coverage/lines_test.tl`'s 8
  test functions pass unchanged against the new types.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast: " _tool/coverage/lines.tl` prints `3` (it prints
  `9` today).
- `grep -c -- "-- cast: .*from any" _tool/coverage/lines.tl` prints `0`
  (it prints `6` today).
- `grep -n '"_tool/coverage/lines.tl"' _build/casts_baseline.tl` shows
  `= 3` (it shows `= 9` today).
- `wc -l _tool/coverage/lines.tl` reports at most 500.
- `bin/cosmic --make test _tool/coverage/lines_test.tl` ends
  `test: PASS (1 file)`.
- `bin/cosmic --make coverage` ends `coverage: PASS` and prints
  `coverage ratchet ok`.
- `git diff --stat origin/main...HEAD` names exactly two files:
  `_tool/coverage/lines.tl` and `_build/casts_baseline.tl`.

## Enablement
none needed. The mechanism is a Teal record declaration plus `is`
dispatch over `any`, both already ubiquitous in this tree and stated in
AGENTS.md ("Use `is` for dispatch past nil ... also dispatch over
`any`"), and the cast floor's regen command is printed by the gate that
fails. The whole shape was applied and gated during this refinement
pass — `--check types` clean, `_tool/coverage` tests green, `fmt: PASS
(527 files)`, `lint: PASS (624 files)`, `coverage: PASS (239 files)`
with `coverage ratchet ok` — so no unknown remains for the implementing
session to discover.
