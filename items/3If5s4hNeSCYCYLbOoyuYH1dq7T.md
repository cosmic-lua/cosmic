## Change

Make BLOB and TEXT distinguishable at the Lua value boundary, in this
repo (cosmic-lua/cosmopolitan) only — the ergonomic distinct type
that consumes this is a separate cosmic-repo follow-up (see below).

`db_push_value` (`tool/net/lsqlite3.c:1085` — moved from the
originally-cited :948 by unrelated upstream growth, same body) and
the structurally separate `vm_push_column` (lines 153-176, used by
`db:rows()`/`db:query()`/`vm:get_value()`, NOT by `db_push_value`)
both marshal `SQLITE_TEXT` and `SQLITE_BLOB` through `lua_pushlstring`
with no way for a caller to tell them apart:

```c
case SQLITE_TEXT:
    lua_pushlstring(L, (const char*)sqlite3_value_text(value), sqlite3_value_bytes(value));
case SQLITE_BLOB:
    lua_pushlstring(L, sqlite3_value_blob(value), sqlite3_value_bytes(value));
```

So a UDF cannot tell `x'00FF'` from the two-character text that
shares its bytes, and neither can a caller reading a column.
`db_push_value` has exactly two callers: `db_sql_normal_function`
(UDF arguments) and `liter_table` (the session/changeset extension's
old/new/conflict values). `vm_push_column` backs every ordinary
column read.

### The decision (settled — board item 3IlL8oOG, confirmed by the
### project owner, 2026-09-03)

Representation: a new accessor exposing the real SQL runtime type,
matching this file's own established idiom of a dedicated method per
SQL type rather than a runtime-type-tagged return value (`bind` vs
`bind_blob` on the way in; `result_blob`/`result_text`/`result_int`/
`result_double` on the way out — no existing binding in this file
hands back a tagged value):

- `value_type(n)` for UDF arguments and session/changeset values
  (`sqlite3_value_type`);
- `column_type(n)` for column reads (`sqlite3_column_type`).

Both are named distinctly from the existing decltype-reporting
`type()`/`get_named_types()` (the *declared* schema type, which
SQLite's dynamic typing can disagree with at runtime) and are called
**separately from** the existing value-getting call — not merged
into a combined `value, type = get(n)` return. Every existing push
stays exactly as-is: still a plain Lua string for both TEXT and
BLOB. This is purely additive — nothing that reads a value today
changes shape, and `db_push_value`'s output has no existing
`cosmic.sqlite` consumer to break (neither `create_function`/
`create_aggregate` nor the session/changeset iterator is wrapped
there today).

Scope: both `db_push_value`'s callers (UDF args, changeset iterator)
and `vm_push_column`'s callers (ordinary column reads) get the new
accessor — not narrowed to UDF arguments only.

The integer-fallback defect described in the original version of
this spec (`PUSH_INT64`'s string fallback for out-of-range
`SQLITE_INTEGER` values) **does not exist on this build**: dropped
from scope. `LUA_INT_TYPE` defaults to `LUA_INT_LONGLONG`
(`third_party/lua/luaconf.h:137,180`, no override in any `BUILD.mk`),
so `lua_Integer` is already 64-bit signed, exactly matching
`sqlite_int64` — the fallback branch is dead code and cannot execute.
No fix, no round-trip test, no follow-up item; there is nothing live
to settle.

### What this item builds

1. `tool/net/lsqlite3.c`: add `value_type(n)` (wired to
   `db_sql_normal_function`'s context / the session/changeset value
   accessors) and `column_type(n)` (wired to `vm`/statement objects),
   both returning the SQLite runtime type constant
   (`sqlite3_value_type`/`sqlite3_column_type`'s own `SQLITE_INTEGER`/
   `_FLOAT`/`_TEXT`/`_BLOB`/`_NULL` values, or a Lua-friendlier
   mapping if this file's existing convention for constant-returning
   accessors says otherwise — check `vm:type()`'s existing return
   shape for precedent before picking).
2. `tool/net/definitions.lua`: annotate both new bindings in the same
   commit, per this repo's binding-contract rule.
3. Round-trip test proving: a UDF can call `value_type(n)` to
   distinguish a BLOB argument from TEXT with identical bytes; a
   column read can do the same via `column_type(n)`; neither new
   accessor changes any existing test's observed value shape.

### Follow-up, NOT part of this item (file separately in cosmic-lua/cosmic)

`cosmic.sqlite`'s ergonomic layer: define a distinct `Blob` wrapper
type, build it on column reads and UDF arguments by checking the new
`column_type`/`value_type` accessors, and teach `cosmic/sqlite/bind.tl`
to dispatch on that type to call `bind_blob` automatically (so a
value read as a `Blob` and later bound back is stored as a BLOB
without the caller having to remember to call `bind_blob` by hand).
This is a separate PR against the cosmic repo, landed once this
repo's pin carries the new accessors — the same split this repo's
AGENTS.md already prescribes for any binding-contract change (frozen
C-boundary contract here, typed wrapper fix as its own change there).

Gate: `make -j$(nproc) o//tool/lua/test`, with the round-trip cases
above.

## Non-goals

- No determinism work; that is its own item.
- No change to how NULL arrives (`lua_pushnil` is correct and cosmic's
  nil-flow doctrine already covers it).
- No wrapper type, no bind-dispatch change, and no other
  `cosmic.sqlite` work in this item — see Follow-up above.
- No fix or test for the `SQLITE_INTEGER` string fallback — it is
  dead code on this build (see Evidence above), not a defect to
  settle here or in any follow-up.
