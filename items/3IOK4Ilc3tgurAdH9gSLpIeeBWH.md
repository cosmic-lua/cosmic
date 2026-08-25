## Goal
G3 — close the **sqlite row column read** class of `from any` casts: 9 of the
tree's 192, classified in `docs/design/casts.md`. A `Row` is `{string: any}`,
so reading a column whose type the caller already knows costs a cast at every
read. Moving that check into three typed readers closes all 9 and gives
`cosmic.sqlite` the accessor its docs already imply.

## Change

Add `cosmic/sqlite/column.tl`, a new internal shard, and export its three
readers from `cosmic/sqlite/init.tl`. Then rewrite the 9 cast sites to call
them.

**1. `cosmic/sqlite/column.tl` (new file).** Declare

```teal
local type Row = {string: any}
```

and three readers over it, each returning the declared type or `nil` plus a
message (the fallible-value shape: two slots, nothing after the error):

| function | signature | accepts |
| --- | --- | --- |
| `text` | `function(row: Row, column: string): string \| nil, string` | `v is string` |
| `number` | `function(row: Row, column: string): number \| nil, string` | `v is number` |
| `integer` | `function(row: Row, column: string): integer \| nil, string` | `v is integer` |

Each reads `local v = row[column]` and narrows with `is` — **no `as` cast
anywhere in this file**. Verified against the tree's pinned tl on 2026-08-25:
`is string`, `is number` and `is integer` all narrow a `{string: any}` element
cast-free, and `is integer` compiles to a `math.type` test, so `3.5` is
rejected at runtime while `7` is accepted.

The three failure messages, exactly:

- `row[column] == nil` → `column "<column>" is absent or NULL`
- `text`, wrong type → `column "<column>" is <type(v)>, want string`
- `number`, wrong type → `column "<column>" is <type(v)>, want number`
- `integer`, wrong type → `column "<column>" is <desc>, want integer`, where
  `desc` is `a float` when `type(v) == "number"` and `type(v)` otherwise

Give each reader the house doc-comment treatment (`---` summary, `@param`,
`@return` per return slot). The module returns a record-typed table
(`local M: ColumnModule = {text = text, number = number, integer = integer}`)
in the same shape as `cosmic/sqlite/bind.tl`.

**2. `cosmic/sqlite/init.tl`.** `require` the new shard, add
`column_text`, `column_number` and `column_integer` to the `record sqlite`
interface and to the `M` table literal, forwarding to the shard's `text`,
`number` and `integer`. The names carry the `column_` prefix because
`sqlite.blob` is already the BLOB *constructor* — a bare `sqlite.blob` reader
would collide with it. Do **not** add a `Row` type alias to the `sqlite`
record; the row type stays spelled `{string: any}` on the public surface.

Measured now: `wc -l < cosmic/sqlite/init.tl` is 453, so 47 lines of headroom
under the 500-line cap; this adds roughly 12.

The doc page needs no separate edit: `_tool/doc/index.tl`'s `flatten_shards`
folds a shard's function docs onto the parent page, filtered by the parent's
own export list — which is exactly how `sqlite.blob` (defined in
`cosmic/sqlite/bind.tl`) already renders under `### blob` in
`bin/cosmic --docs sqlite`. Exporting from `init.tl` is what publishes them.

**3. `cosmic/sqlite/column_test.tl` (new file).** Cover all three readers:
the happy path per type, the absent-column message, the wrong-type message,
and `integer` rejecting a float. Follow the house test form — one `test_*`
function called on the line after its `end`.

**4. The 9 cast sites.** Replace each `row.<col> as string` with
`check.must(sqlite.column_text(row, "<col>"))` and each
`(row.<col> as number)` with `check.must(sqlite.column_number(row, "<col>"))`,
deleting the now-unneeded `-- cast: from any` comment on each line. All three
files already `require` both `cosmic.check` and `cosmic.sqlite`. Measured
2026-08-25 against `dbca9e77` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

| file | lines | reader |
| --- | --- | --- |
| `cosmic/sqlite/advanced_test.tl` | 434, 456 | `column_text` (456 has two casts on one line) |
| `cosmic/sqlite/close_test.tl` | 129 | `column_text` |
| `cosmic/sqlite/init_test.tl` | 176, 194, 431 | `column_text` (431 has two casts on one line) |
| `cosmic/sqlite/init_test.tl` | 101, 228, 403 | `column_number` |

`cosmic/sqlite/init_test.tl` is 491 lines — **9 lines of headroom** — so the
rewrite must stay effectively line-neutral: each site drops its `-- cast:`
comment line and may spend that line on a wrap. `advanced_test.tl` is 476
(24 lines of headroom). Both bounds are Acceptance commands below.

**5. `_build/casts_baseline.tl`.** The closure lowers three rows. Run exactly
the regen command the gate's failure message prints
(`bin/cosmic --make run _build/casts.tl --baseline`) and commit the result;
same for the coverage floor if `--make ci` asks for it. Read the regenerated
diff before committing: only the rows this change touches may move — a
*lowered* row anywhere else means the regen ran against a partial tree, so
re-run it, never commit it.

## Non-goals

- **No `column_blob` reader.** Measured 2026-08-25 by inserting
  `sqlite.blob("\1\2\3")` and reading it back: a BLOB column arrives as a Lua
  `string`, indistinguishable from TEXT, so a blob reader would be a synonym
  for `column_text` that asserts nothing extra. Not shipped, not stubbed.
- **No nullable variant.** An absent column and a SQL NULL both read as `nil`
  off a `Row` and the readers do not distinguish them; a caller that wants a
  nullable column keeps reading `row.x` directly. Do not add a `column_*_or_nil`
  family or a fourth return slot to work around this.
- **No per-row metatable, and no change to the row's runtime shape.** The rows
  built in `cosmic/sqlite/row_iter.tl`'s `__call` are on the query hot path;
  the readers are free functions over a plain table precisely so that path is
  untouched. Do not change `Rows`' `__call`/`__close` signatures, `db:query`,
  `db:query_one`, or `stmt:rows`.
- **Do not touch the other `from any` sites under `cosmic/sqlite/`.**
  `cosmic/sqlite/bind.tl` (2) and `cosmic/sqlite/extras.tl` (4) are the
  dynamic-value-boundary class and belong to item `3IOK4SZH`;
  `cosmic/sqlite/close_test.tl` lines 62 and 179 (`mt["__close"] as
  function(any, any)`) are the same class. `close_test.tl`'s baseline row goes
  5 → 4, not to zero.
- **Do not rewrite `docs/design/casts.md`.** It is a dated census against
  `d3e59de7` and is meant to read as one; re-measuring it is separate work.
- **No new `*_example.tl` entries** and no edits to `cosmic/sqlite/init_example.tl`.
- No cast may be added anywhere in the diff, and no gate is weakened or
  exempted to make the numbers move.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/sqlite/column_test.tl` passes.
- `grep -n -- "-- cast: .*from any" cosmic/sqlite/advanced_test.tl cosmic/sqlite/init_test.tl`
  prints nothing (today: 8 lines).
- `grep -c -- "-- cast: .*from any" cosmic/sqlite/close_test.tl` reports `2`
  (today `3`) — the two that remain are the `__close` metamethod reads named
  in `Non-goals`, not row column reads.
- `grep -c -- "-- cast: " cosmic/sqlite/column.tl cosmic/sqlite/column_test.tl`
  reports `0` for both files — every cast in this tree carries a justification,
  so zero justifications is zero casts.
- `grep -n "cosmic/sqlite/" _build/casts_baseline.tl` shows no
  `advanced_test.tl` row, no `init_test.tl` row, and
  `["cosmic/sqlite/close_test.tl"] = 4`. Today those three rows are `2`, `6`
  and `5`.
- `bin/cosmic --docs sqlite` prints a `### column_text`, a `### column_number`
  and a `### column_integer` section under `## Functions`. Today it prints
  none of the three.
- `wc -l cosmic/sqlite/init.tl cosmic/sqlite/init_test.tl cosmic/sqlite/advanced_test.tl cosmic/sqlite/column.tl cosmic/sqlite/column_test.tl`
  reports every file at 500 or below. Today the first three are 453, 491 and 476.

## Enablement

none needed. Every wrong turn this spec predicts is already caught by a gate
that exists — the cast justification lint and `_build/casts.tl`'s ratchet catch
a cast smuggled into the new shard, `--check types` catches a narrowing that
does not hold, `--check lint` catches the 500-line cap, and the coverage
ratchet catches an untested reader — so the countermeasures are the walls in
`Non-goals` rather than new machinery. The two facts a builder could not have
looked up (that `is integer` narrows a `{string: any}` element cast-free, and
that a BLOB column comes back as a Lua string) were measured during this
refinement and are stated above with what produced them.
