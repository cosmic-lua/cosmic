## Goal
G3 — an honest type layer. This item's parent is "casts: close the 55
any-map field walk from-any sites", and this is its tl-syntax-tree
slice: 6 of the 55, in one file, over a shape whose generator already
exists.

## Evidence

Measured 2026-08-25 against `dbca9e77` with
`grep -n -- "-- cast: " _tool/coverage/lines.tl`: the file carries 9
cast justifications in 134 lines, 6 of them `from any` and in this
class:

```
29:  local kind = node["kind"] as string
30:  local y = node["y"] as integer
44:    local exp = node["exp"] as {any: any}
46:      out[exp["y"] as integer] = true
51:    local blocks = node["if_blocks"] as {{any: any}}
55:          out[block["y"] as integer] = true
```

The other 3 are `array view of ast map` (`:75`, `:87`) and `ast node as
generic map` (`:122`) — a different justification, and whether they
fall out of the same fix is a question for refinement, not an
assumption to write into a Change.

Every site indexes a tl syntax-tree node held as `{any: any}` and
lifts a field the tl AST genuinely has: `kind`, `y`, `exp`,
`if_blocks`. The fields are real and stable; nothing describes them in
a type.

**Two candidate sources for the record, and picking between them is
this item's real work.** `_types/gentl.tl` extracts `tl.d.tl` from the
pinned tl source, narrowed to a public API with records curated to
verified field subsets, and it is generated into
`o/_types/types_gen/` by every verb that touches the graph. Separately
`cosmic/_teal_ast.tl` exists in the tree. Whether the Node record
should be generated (tracking the pin, and drifting when tl bumps) or
hand-declared as the field subset this one walker actually reads is a
decision, and AGENTS.md's rule that the generated types are never
committed constrains it.

## Direction, not a decision

Declare the node shape the coverage walker reads and index it as a
record. The open questions a refinement pass must settle:

- Generated from the pin via `_types/gentl.tl`, or hand-declared in
  `_tool/`? A generated record cannot be committed, which affects where
  the declaration can live.
- Whether the walker's field subset is complete. It reads `kind`, `y`,
  `exp`, `if_blocks` today; a record narrower than the AST is fine, but
  the spec must enumerate the fields it declares.
- Whether the 3 non-`from any` casts in the same file
  (`array view of ast map`, `ast node as generic map`) close as a side
  effect or stay. Either is acceptable; the spec must say which, and
  Acceptance must carry the resulting `grep -c -- "-- cast: "` bound
  for the file.
- `_tool/**` is internal and never ships in a user artifact, so this
  slice moves no public surface. Confirm that against
  `_build/public_surface_baseline.tl` rather than assuming it.

## What this must not do

The coverage line-mapping behaviour is frozen: this slice changes how
node fields are TYPED, not which lines the walker reports. A change in
reported lines moves `.cosmic-coverage` rows for reasons unrelated to
coverage, which is exactly the confusion to avoid — if the committed
floor moves at all here, that is a signal the walk changed and the
diff is wrong.

No tl pin bump. No change to `_types/gentl.tl`'s erasure rules beyond
what declaring this record requires.

The closure diff lowers the affected row in
`_build/casts_baseline.tl` and updates the per-file table in
`docs/design/casts.md`. Run exactly the regen command the gate's
failure message prints and commit the result; no gate is weakened any
other way.
