## Evidence

`friction: 2026-09-04 work9 reconciliation tail` (item «NJCj_HQIX»)
records that `item.tl`'s `builders: {string}` field is typed as a Lua
array in the in-memory `Item` record, but `decode` expects a
space-joined string on the wire. Nothing next to the field
declaration says so; a reviewer writing a fixture from scratch during
review round 3 of «FacE_b8sh» hit a shape error before discovering
the mismatch, costing roughly five tool calls (three failed scratch
attempts) before landing on the working shape.

## Change

`_work/item.tl`: a one-line doc comment on the `builders` field
naming the wire-shape mismatch — that `decode` expects the field as a
space-joined string, not the in-memory array — so a reader writing a
fixture by hand sees the shape before hitting the error.

## Non-goals

No change to `decode` or the field's in-memory type; this is
documentation only.
