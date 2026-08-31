## Change

Expose SQLite user-defined functions on `cosmic.sqlite`, so a cosmic program can
write SQL functions in Teal.

The C already exists and is unexposed. `tool/net/lsqlite3.c` implements
`db_register_function` and publishes three methods on the db metatable:

```c
{"create_function",     db_create_function      },
{"create_aggregate",    db_create_aggregate     },
{"create_collation",    db_create_collation     },
```

`create_function(name, nargs, fn[, udata])`, `create_aggregate(name, nargs, step,
final)`. Nothing under `cosmic/sqlite/` mentions them, so this is a Teal wrapper
over an existing binding.

### The value type is honest without a cast

`db_push_value` marshals TEXT and BLOB to Lua strings, FLOAT to a number, INTEGER to
an int64, and NULL to `nil`. Those are distinct Teal runtime types, so a UDF
argument types as `number | string | nil` and the body narrows it with `is` — the
same latent-nil obligation the rest of the library carries, not an escape hatch. The
boundary needs no `as` at all, which is what makes this wrapper worth typing rather
than passing `any` through.

`nil` means SQL NULL, and the doc comment must say so: it is a value, not an absent
argument.

### Determinism is part of the signature

A UDF registered without `SQLITE_DETERMINISTIC` cannot be used in an index on an
expression and is re-evaluated per row. The wrapper takes it as an explicit option
and defaults to volatile, matching the C default. A function marked deterministic
that is not produces wrong results rather than an error, so the wrapper's docs carry
that warning where the caller reads it.

### Files

- `cosmic/sqlite/init.tl` (or a new `cosmic/sqlite/udf.tl` if `init.tl` is near the
  line cap — check before writing) — `create_function`, `create_aggregate`,
  `create_collation`, each returning `boolean, string`.
- `cosmic/sqlite/types.tl` — the SQL value type and the UDF options record.
- Tests: a scalar function called from SQL; an aggregate over a table; a collation
  changing an `ORDER BY`; a NULL argument narrowing correctly; a deterministic
  function usable in an index on an expression.
- `cosmic/sqlite/udf_example.tl` with `Example_*`, since this is a headline
  capability and the examples are what `--docs` serves.

### Why this is blocked

Both boundary defects are C-side and both change this wrapper's contract, so landing
the wrapper first would mean shipping a documented-defect API and then breaking it:

- determinism is not expressible at all today;
- BLOB and TEXT are indistinguishable, and the chosen blob representation decides
  what a UDF argument's Teal type actually is.

## Non-goals

- No extension registration; that is a separate item.
- No new C. If the boundary needs more than the two blocking items provide, that is
  a finding for those items, not work here.
