## Goal

`Database:prepare`'s second return value should be a dedicated error
string on failure, not a slot shared between the success remainder
(the unparsed SQL tail, a string) and the failure code (a bare
integer) — the `unix.nanosleep` archetype cited by this item's parent
census.

## Evidence

- C source: `tool/net/lsqlite3.c:1597-1617`:
  ```c
  static int db_prepare(lua_State *L) {
      ...
      if (sqlite3_prepare_v2(db->db, sql, sql_len, &svm->vm, &sqltail) != SQLITE_OK) {
          lua_pushnil(L);
          lua_pushinteger(L, sqlite3_errcode(db->db));   /* slot 2: number on failure */
          ...
          return 2;
      }
      lua_pushstring(L, sqltail);                        /* slot 2: string on success */
      return 2;
  }
  ```
- `tool/net/definitions.lua:867-876`:
  ```
  ---@param sql string
  ---@return lsqlite3.Statement|nil stmt compiled statement, or nil when compilation fails
  ---@return string|lsqlite3.ResultCode tail SQL past the first statement on success; the error code on failure (fetch the message with db:errmsg())
  ---@nodiscard
  function lsqlite3.Database:prepare(sql) end
  ```
  The doc comment itself concedes the workaround ("fetch the message
  with `db:errmsg()`") — the caller cannot get a message from the
  return value at all on failure.
- Probe (cosmopolitan repo root, `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local db=s.open_memory(); local st,c=db:prepare("NOT VALID SQL"); print(st,c,type(c))'
  nil	1	number
  ```
- cosmic-side spend: `cosmic/sqlite/init.tl:268-277` and
  `cosmic/sqlite/stmt_cache.tl:55-70`, both structured identically:
  ```teal
  local raw_stmt = raw_db:prepare(sql)
  if not raw_stmt then
    return nil, raw_db:errmsg()
  end
  ```
  Neither call site ever reads `prepare`'s slot 2 — both re-fetch the
  message via a second call to `db:errmsg()`, precisely because the
  raw slot 2 is not usable as a message.

## Change

In `tool/net/lsqlite3.c`'s `db_prepare` (~line 1606-1611), push the
error message directly instead of the bare code:
```c
if (sqlite3_prepare_v2(db->db, sql, sql_len, &svm->vm, &sqltail) != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushstring(L, sqlite3_errmsg(db->db));
    lua_pushinteger(L, sqlite3_errcode(db->db));
    if (cleanupvm(L, svm) == 1) lua_pop(L, 1);
    return 3;
}
lua_pushstring(L, sqltail);
return 2;
```
Update `tool/net/definitions.lua:872-874` to reflect the widened,
now-honest shape, e.g.:
```
---@return lsqlite3.Statement|nil stmt
---@return string? tail_or_error SQL past the first statement on success; the error message on failure
---@return lsqlite3.ResultCode? errorcode present on failure only
```
(keep documenting that slot 2 still doubles as tail-on-success — that
asymmetry is inherent to the underlying C API and is fine, as long as
the FAILURE case is a string, matching this repo's own rule that "slot
2 is the error" whenever slot 1 admits nil).

## Non-goals

- No change to `cosmic/sqlite/init.tl` or `stmt_cache.tl` in this PR —
  both already work correctly via `db:errmsg()`; once slot 2 carries a
  real string on failure they could simplify, but that's a separate,
  cosmic-side follow-up for the goal owner to sequence, not required
  here.
- No change to the success path's tail-string behavior.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes.
- Re-running the probe above shows a string (not a bare integer) in
  slot 2 on the bad-SQL failure path.
- The success path (`db:prepare("SELECT 1")`) is unaffected — slot 2
  is still the empty/tail string.
- `tool/net/lsqlite3.c` and `tool/net/definitions.lua` updated in the
  same commit.
