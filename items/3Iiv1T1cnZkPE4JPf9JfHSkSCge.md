## Goal

`Database:wal_checkpoint`'s failure return should carry a string error
message, not a bare SQLite numeric result code with no text.

## Evidence

- C source: `tool/net/lsqlite3.c:931-942`:
  ```c
  static int db_wal_checkpoint(lua_State *L) {
      sdb *db = lsqlite_checkdb(L, 1);
      int eMode = luaL_optinteger(L, 2, SQLITE_CHECKPOINT_PASSIVE);
      const char *db_name = luaL_optstring(L, 3, NULL);
      int nLog, nCkpt;
      if (sqlite3_wal_checkpoint_v2(db->db, db_name, eMode, &nLog, &nCkpt) != SQLITE_OK) {
          return pusherr(L, sqlite3_errcode(db->db));   /* nil, integer */
      }
      lua_pushinteger(L, nLog);
      lua_pushinteger(L, nCkpt);
      return 2;
  }
  ```
- `tool/net/definitions.lua:974-978`:
  ```
  ---@param mode integer?
  ---@param name string?
  ---@return integer|nil nlog, integer nckpt
  ---@return lsqlite3.ResultCode? errno
  function lsqlite3.Database:wal_checkpoint(mode, name) end
  ```
- Probe (cosmopolitan repo root, `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local db=s.open_memory(); local nlog,nckpt=db:wal_checkpoint(nil,"nosuchdb"); print(nlog,type(nlog),nckpt,type(nckpt))'
  nil	nil	1	number
  ```
  An unattached database `name` is a correct, data-dependent case any
  caller with a typo or a stale name can meet.
- cosmic-side spend: `grep -rn 'wal_checkpoint' cosmic/` — zero call
  sites.

## Change

In `tool/net/lsqlite3.c`'s `db_wal_checkpoint` (~line 936-938), push
the error message alongside the code:
```c
if (sqlite3_wal_checkpoint_v2(db->db, db_name, eMode, &nLog, &nCkpt) != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushstring(L, sqlite3_errmsg(db->db));
    lua_pushinteger(L, sqlite3_errcode(db->db));
    return 3;
}
```
Update `tool/net/definitions.lua:976-977` to:
```
---@return integer|nil nlog, integer nckpt
---@return string? errormsg
---@return lsqlite3.ResultCode? errno
```

## Non-goals

- No change to the success-path return shape (`nlog, nckpt`).
- No change to default `mode`/`name` argument handling.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes.
- Re-running the probe above shows a string in the new error-message
  slot on the unattached-name failure path.
- `tool/net/lsqlite3.c` and `tool/net/definitions.lua` updated in the
  same commit.
