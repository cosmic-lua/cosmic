## Change

Let a Lua-defined SQL function be marked deterministic.

`lsqlite3`'s `db_register_function` passes only `SQLITE_UTF8` to
`sqlite3_create_function`:

```c
result = sqlite3_create_function(
    db->db, name, args, SQLITE_UTF8, func, ...);
```

and the flag appears nowhere in the file:

```
$ grep -c SQLITE_DETERMINISTIC tool/net/lsqlite3.c
0
```

So every Lua UDF is volatile to SQLite. The consequences are not cosmetic: a
volatile function cannot appear in an index on an expression, cannot be used in a
partial index predicate, is re-evaluated per row instead of being factored out of a
loop, and blocks some query-plan rewrites. That is the difference between UDFs
being a convenience and being usable in the schema.

Add the flag as an opt-in on `create_function` and `create_aggregate` — the caller
declares determinism, because only the caller knows. Default stays volatile, which
is the safe default and preserves current behaviour for existing callers.

Determinism is a promise SQLite will hold the caller to: a function marked
deterministic that returns different values for the same arguments produces wrong
results, not an error. The binding should say so where callers read it, and
`definitions.lua` must gain the parameter in the same commit, per this repo's
convention that a binding change and its annotation land together.

Gate: `make -j$(nproc) o//tool/lua/test`, with a case proving a deterministic UDF
is usable in an index on an expression and a volatile one is refused there.

## Non-goals

- No change to how values cross the UDF boundary; that is the blob/text item.
- No change to the default (volatile).
