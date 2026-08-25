`cosmic.shape` cannot describe a table keyed by integers that is not a
dense list, so two `from any` casts cannot be closed by the validating
decode the rest of their class uses.

`_tool/coverage/report.tl:227` and `:235` shape loaded coverage data
into `{string: {integer: integer}}` — a file-path map whose values are
sparse line-number-keyed hit counts. Neither combinator fits:
`shape.map` refuses a non-string key (`cosmic/shape.tl:179`) and
`shape.list` refuses keys that are not dense `1..n`
(`cosmic/shape.tl:164`, via `count_keys` at `:100`).

Found while refining `3IOeg86u` (close the 23 decoded-data shaping
sites in non-test code), which excluded these two sites for this
reason; the other 21 close as specified.

The question to settle is whether `cosmic.shape` grows a combinator for
this — `shape.intmap(of)`, or a `shape.map` that takes a key Spec — or
whether a sparse integer-keyed table is a shape the mechanism should
deliberately refuse, leaving those two casts justified as they are. It
is a `cosmic.*` public-API decision, so whichever way it goes it wants
the reasoning written down.
