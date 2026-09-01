## Goal

`lsqlite3.config`'s failure return should carry a string error message
in slot 2 (this repo's own convention), not a bare SQLite numeric
result code with no explanatory text at all.

## Evidence

- C source: `tool/net/lsqlite3.c:2461-2499`:
  ```c
  static int lsqlite_config(lua_State *L) {
      int rc = SQLITE_MISUSE;
      int option = luaL_checkint(L, 1);
      switch (option) {
          case SQLITE_CONFIG_SINGLETHREAD:
          case SQLITE_CONFIG_MULTITHREAD:
          case SQLITE_CONFIG_SERIALIZED:
              if ((rc = sqlite3_config(option)) == SQLITE_OK) { ... return 1; }
              break;
          case SQLITE_CONFIG_LOG:
              ... return 3;
      }
      return pusherr(L, rc);   /* nil, integer rc — no string anywhere */
  }
  static int pusherr(lua_State *L, int rc) {
      lua_pushnil(L);
      lua_pushinteger(L, rc);
      return 2;
  }
  ```
  The same `pusherr(L, rc)` fallthrough serves two distinct reachable
  cases: (a) `option` outside the four documented values, and (b) a
  documented, valid option whose underlying `sqlite3_config()` call
  itself fails (e.g. called after SQLite has already initialized) — a
  genuine environmental failure a correct, well-sequenced caller can
  meet. Both return the identical `nil, <int>` shape.
- `tool/net/definitions.lua:576-595`:
  ```
  ---@param option integer
  ---@param func function? callback for `lsqlite3.CONFIG_LOG`, or `nil` to remove it
  ---@param udata any? user data passed to the log callback
  ---@return integer|nil rc, function? prev_func, any prev_udata
  ---@return integer? errorcode
  function lsqlite3.config(option, func, udata) end
  ```
- Probes (cosmopolitan repo root, `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local rc,e=s.config(999999); print(rc,e,type(e))'
  nil	21	number
  $ o//tool/lua/lua -e 'local s=require("cosmo.lsqlite3"); local db=s.open_memory(); local rc,e=s.config(s.CONFIG_SINGLETHREAD); print(rc,e,type(e))'
  nil	21	number
  ```
  (`21` = `SQLITE_MISUSE`.) The second probe shows the environmental
  path: `open_memory()` already ran `sqlite3_initialize()`, and SQLite
  refuses `sqlite3_config()` after initialization — a correct caller
  that opens a database before later trying to change the threading
  mode meets this legitimately, with no way to recover a human-readable
  message from the return value alone.
- cosmic-side spend: `grep -rn 'lsqlite3.config\|sqlite3.config' cosmic/`
  — zero call sites.

## Change

In `tool/net/lsqlite3.c`, change `pusherr` (or add a config-specific
variant) to push `sqlite3_errstr(rc)` in slot 2 instead of the bare
integer, keeping the integer code as an optional slot 3 `errno`:
```c
lua_pushnil(L);
lua_pushstring(L, sqlite3_errstr(rc));
lua_pushinteger(L, rc);
return 3;
```
Update `tool/net/definitions.lua:590-594` to:
```
---@return integer|nil rc, function? prev_func, any prev_udata
---@return string? errormsg
---@return integer? errorcode
```
Separately, consider (implementer's judgment, not required by this
capture) raising via `luaL_argerror` for an `option` outside the four
documented values, matching the `path.join`-class precedent — but
that is a design choice for the fix's author, not gated by this
capture's acceptance bar.

## Non-goals

- No change to the `CONFIG_LOG` success path (`return 3` at line
  2496) — its three-value success shape (`OK, prev_func, prev_udata`)
  is unaffected and out of scope.
- No decision here on whether to also raise on an undocumented
  `option` value — noted as a follow-on option above, not required.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes.
- Re-running the probes above shows a non-empty string in slot 2 on
  both the invalid-option and the lifecycle-failure paths.
- `tool/net/lsqlite3.c` and `tool/net/definitions.lua` updated in the
  same commit.
