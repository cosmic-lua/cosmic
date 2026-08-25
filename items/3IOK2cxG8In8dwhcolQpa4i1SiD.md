G3 — close the **any-map field walk** class of `from any` casts: 55 of
the tree's 192, measured 2026-08-25 against `d3e59de7` and mapped in
`docs/design/casts.md`. The code indexes a value it knows is a table
but whose type is `any` or `{string: any}`, one field at a time down a
path, so a two-level read costs two casts on one line
(`cosmic/quicksand/box/merge_test.tl:22`). The files and their site
counts: _tool/coverage/lines.tl (6), cosmic/check.tl (2),
cosmic/deep_example.tl (5), cosmic/deep_test.tl (8),
cosmic/fetch/headers.tl (2), cosmic/fetch/init.tl (3),
cosmic/format/init.tl (4), cosmic/fs/types.tl (2),
cosmic/quicksand/box/init_test.tl (2), cosmic/quicksand/box/merge.tl
(4), cosmic/quicksand/box/merge_test.tl (14),
cosmic/quicksand/proxy/rules.tl (1), cosmic/sandbox/init_test.tl (2).
No mechanism is missing: the values are box configuration, tl
syntax-tree nodes and coverage records — real shapes that no record
describes — so the work is declaring a record per shape, and using `is
{string: any}` dispatch where the value genuinely is dynamic. The box
configuration alone (merge.tl plus its test, 18 sites) is the natural
first slice. The closure diff must lower the affected rows in
`_build/casts_baseline.tl` — run exactly the regen command the gate
prints and commit the result.
