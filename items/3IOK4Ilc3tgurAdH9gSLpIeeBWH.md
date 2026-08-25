G3 — close the **sqlite row column read** class of `from any` casts: 9
of the tree's 192, measured 2026-08-25 against `d3e59de7` and mapped in
`docs/design/casts.md`. A `Row` is `{string: any}`, so reading a column
whose type the caller knows costs a cast at every read (`row.name as
string`, `(row.c as number)`). The files and their site counts:
cosmic/sqlite/advanced_test.tl (2), cosmic/sqlite/close_test.tl (1),
cosmic/sqlite/init_test.tl (6). The row's dynamic shape is real — a
query's columns are known only at runtime — so the record cannot be
typed and the closing mechanism is typed column accessors on `Row`: a
`text`, `number`, `integer` and `blob` reader taking the column name
and returning the declared type or failing. That moves the check from
every caller's cast into one place that can fail honestly, and it is a
public `cosmic.sqlite` surface change, so it needs a `--docs` entry and
the doc-comment treatment. The closure diff must lower the affected
rows in `_build/casts_baseline.tl` — run exactly the regen command the
gate prints and commit the result.
