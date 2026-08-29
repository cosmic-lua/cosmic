## Change

`_work/item.tl`'s `decode` validates through `cosmic.shape` instead of
hand-coercing every field.

Measured 2026-08-29: `grep -c 'tostring(t\.' _work/item.tl` → 14, plus
a `tonumber` for `pr`, all over the `{string: any}` that
`literal.parse_file` returns; `grep -rn "shape\." _work/*.tl` outside
tests → 0 hits. `cosmic.shape` (in the pinned stdlib; `cosmic --docs
shape`) exists for exactly this boundary: `shape.into(raw, SPEC)` walks
the value against a Spec built from `shape.record`/`shape.string`/
`shape.integer`/`shape.map`/`shape.optional`, ignores keys the Spec
does not name (which preserves decode's retired-field tolerance), and
coerces nothing.

The change, in `_work/item.tl` (318 lines now —
`wc -l < _work/item.tl`):

1. Declare one `SPEC` beside the `Item` record: optional `shape.string`
   for id, title, parent, repo, claim, reviewer, verdict, verdict_head,
   verdict_spec, resolution, and for the three space-joined list fields
   (blocked_by, beats, builders — they validate as strings, the split
   stays a transform); optional `shape.integer` for pr; optional
   `shape.map(shape.string)` for block_reason.
2. `decode` becomes: `shape.into(t, SPEC)`, a refusal propagating as
   `nil, err` exactly as today; then the existing transforms (split the
   three lists, default absent fields to ""/0/{}), then the existing
   `problems(it)` check unchanged. Every `tostring(t.…)` and the
   `tonumber` line deletes; nothing else about the Item record, the
   encode half, or the rules moves.
3. Tests in `_work/item_test.tl`: a well-typed table decodes as before
   (existing roundtrip tests keep passing unchanged); a table with a
   wrong-typed field (`pr = "seven"`) now refuses with shape's dotted-
   path error where the old coercion silently produced 0 — pin the
   refusal; a table carrying an unknown retired key still decodes.

Validation the builder runs locally (not a committed test): decode
every `items/*.tl` in the checkout through the new path and confirm
zero refusals — the encode half has always written well-typed values
(`pr` an integer, strings as strings), so the live board must pass
unchanged; a refusal there is a bounce, not a workaround.

## Non-goals

`encode`, the `problems` rules, and every field's semantics are
unchanged — this deletes coercion, not behaviour, except the pinned
wrong-type refusal which was silent data corruption before.
`_work/gh.tl`'s JSON boundary is a separate later slice; do not touch
it.
