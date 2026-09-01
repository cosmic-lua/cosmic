## Goal

Bring `lsqlite3.open`/`lsqlite3.open_memory`'s failure tuple in line
with this repo's own contract (AGENTS.md: "the error always in slot
2 and nothing else sharing a slot" for a fallible `value|nil, err,
errno?` return) — today the numeric code sits in slot 2 and the
string message in slot 3, the reverse of the documented convention.

## Evidence

- C source: `tool/net/lsqlite3.c:2407-2437`:
  ```c
  static int lsqlite_do_open(lua_State *L, const char *filename, int flags) {
      ...
      if (sqlite3_open_v2(filename, &db->db, flags, 0) == SQLITE_OK) {
          ...
          return 1;
      }
      lua_pushnil(L);
      lua_pushinteger(L, sqlite3_errcode(db->db));   /* slot 2: number */
      lua_pushstring(L, sqlite3_errmsg(db->db));     /* slot 3: string */
      cleanupdb(L, db);
      return 3;
  }
  static int lsqlite_open(lua_State *L) { ... return lsqlite_do_open(L, filename, flags); }
  static int lsqlite_open_memory(lua_State *L) { return lsqlite_do_open(L, ":memory:", ...); }
  ```
  Both bindings call the same `lsqlite_do_open`, so the defect and fix
  are identical for both.
- `tool/net/definitions.lua:552-567`:
  ```
  ---@return lsqlite3.Database|nil db
  ---@return lsqlite3.ResultCode? errorcode
  ---@return string? errormsg
  function lsqlite3.open(filename, flags) end
  ...
  ---@return lsqlite3.Database|nil db
  ---@return lsqlite3.ResultCode? errorcode
  ---@return string? errormsg
  function lsqlite3.open_memory() end
  ```
- Probes (cosmopolitan repo root, `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local db,code,msg=s.open("/nonexistent_dir_zzz_9f3/x.db",s.OPEN_READONLY); print(db,code,type(code),msg,type(msg))'
  nil	14	number	unable to open database file	string
  ```
  `open_memory()`'s failure branch is unreachable outside OOM (opening
  `":memory:"` essentially always succeeds) but shares the exact same
  code path and tuple shape by construction (`lsqlite_do_open`), so the
  fix applies identically.
- cosmic-side spend: `cosmic/sqlite/init.tl:410-430` calls
  `sqlite3.open(...)`, captures `errcode`/`errmsg` into separate
  locals, and reassembles `nil, errmsg or ("error code " ..
  tostring(errcode))` by hand — a direct workaround for the tuple
  being unusable as a plain `T|nil, string`.
  `lsqlite3.open_memory` has zero cosmic call sites — cosmic always
  opens `":memory:"` through `sqlite3.open(":memory:")` instead.

## Change

In `tool/net/lsqlite3.c`, in `lsqlite_do_open` (~line 2417-2420), swap
the push order so the string error message is slot 2 and the numeric
SQLite result code is slot 3:
```c
lua_pushnil(L);
lua_pushstring(L, sqlite3_errmsg(db->db));     /* slot 2: string */
lua_pushinteger(L, sqlite3_errcode(db->db));   /* slot 3: number */
```
Update `tool/net/definitions.lua:552-567` (both `open` and
`open_memory`) to match:
```
---@return lsqlite3.Database|nil db
---@return string? errormsg
---@return lsqlite3.ResultCode? errorcode
```
This is a binding contract change per this repo's own AGENTS.md rule
("a contract change to conform is made deliberately... conformance
probe same PR") — land the `definitions.lua` update in the same
commit as the C change.

## Non-goals

- No change to `lsqlite_config` (see the sibling capture for
  `lsqlite3.config`'s own, separate slot-2 deviation) even though it
  shares the same `pusherr` helper family — that is a distinct
  binding with its own capture.
- No change to `cosmic/sqlite/init.tl`'s call site in this PR; once the
  contract changes, a *separate*, cosmic-side PR simplifies the
  errcode/errmsg juggling at `cosmic/sqlite/init.tl:410-430` — flagged
  here for the goal owner to sequence, not done as part of this
  capture.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes, including
  `test_definitions_conformance.lua`'s check that `lsqlite3.open`'s
  actual arity/shape matches its declared annotation.
- Re-running the probe above shows the string message in slot 2 and
  the integer code in slot 3.
- `tool/net/lsqlite3.c` and `tool/net/definitions.lua` are updated in
  the same commit (per this repo's own binding-contract rule).
