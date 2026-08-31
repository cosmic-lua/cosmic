## Change

Make BLOB and TEXT distinguishable at the Lua value boundary.

`db_push_value` (`tool/net/lsqlite3.c:948`) marshals both to a Lua string:

```c
case SQLITE_TEXT:
    lua_pushlstring(L, (const char*)sqlite3_value_text(value), sqlite3_value_bytes(value));
case SQLITE_BLOB:
    lua_pushlstring(L, sqlite3_value_blob(value), sqlite3_value_bytes(value));
```

So a UDF cannot tell `x'00FF'` from the two-character text that shares its bytes,
and a function that should reject binary input cannot. The same collapse applies
wherever `db_push_value` is used, not only to UDFs.

A second defect sits in the same switch and should be settled with it: `SQLITE_INTEGER`
goes through `PUSH_INT64`, whose fallback pushes the value **as a string** when it
does not fit the Lua integer representation. So a numeric column is not reliably a
number, and a UDF that adds its arguments fails on large integers with a type error
rather than a range error.

### The decision

Pick a representation for blob values and apply it consistently on the way in and
the way out. Candidates, each with a real cost:

- a wrapper userdata or table carrying the bytes — unambiguous, but changes what
  every existing reader of a blob column receives;
- a separate accessor that reports the SQL type alongside the value, leaving the
  pushed value as-is — additive and non-breaking, but leaves the ambiguity in place
  for anyone who does not ask;
- push blobs as a distinct Lua type only inside UDF arguments, leaving column reads
  alone — narrower blast radius, at the cost of two conventions in one binding.

`cosmic.sqlite` already has blob handling on its bind and column paths
(`cosmic/sqlite/bind.tl`, `cosmic/sqlite/column.tl`), so whichever is chosen has a
downstream consumer whose behaviour changes; the cosmic wrapper item depends on
this decision and cannot be specified until it lands.

Binding contracts are frozen at the C boundary in this repo, so a change here is a
deliberate contract change: it needs the matching `definitions.lua` update in the
same commit and a type regen plus wrapper fix on the cosmic side as its own change.

Gate: `make -j$(nproc) o//tool/lua/test`, with round-trip cases proving a blob
survives a UDF unchanged and is distinguishable from text with identical bytes.

## Non-goals

- No determinism work; that is its own item.
- No change to how NULL arrives (`lua_pushnil` is correct and cosmic's nil-flow
  doctrine already covers it).
