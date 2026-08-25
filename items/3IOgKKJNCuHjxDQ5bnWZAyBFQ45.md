A record whose field is NAMED `record` or `enum` renders with zero
fields in `cosmic --docs`, silently: the whole field table vanishes and
the section header is left empty.

`_tool/doc/init.tl:126`, inside `find_record_end`, counts any full
identifier `record` or `enum` as opening a nested block:

```teal
if word == "record" or word == "enum" then depth = depth + 1
```

It already skips string literals and comments — the doc comment above it
records an earlier version of exactly this bug ("an unguarded `end` in a
field's doc comment") — but a field DECLARATION whose name is one of
those words is neither. `record: function(fields: {string: Spec}): Spec`
pushes depth to 2, the record's own `end` returns it to 1, the scan runs
off the end of the file, and `find_record_end` returns its initial
`rec_end`, so `parse_record_fields` is handed an empty body.

Observed on `cosmic/shape.tl` (added by the item this was filed from):
`o/bin/cosmic --docs shape` prints `### ShapeModule` followed by nothing,
while `o/bin/cosmic --docs json` prints `JsonModule`'s full body. The
module's `list`, `map`, `record`, `optional` and `into` still render —
they are file-level functions — but `shape.string`, `shape.number`,
`shape.integer`, `shape.boolean` and `shape.any` are only described as
fields of that record, so they are undocumented in the served reference.

The fix is a lookahead at the same site: an identifier followed by `:`
(or by `=` for `type record = ...`) is a field name, not a block opener.
The failure is silent — no gate notices a record that renders empty —
so a check that a module record with declared fields renders at least
one is worth considering alongside it.
