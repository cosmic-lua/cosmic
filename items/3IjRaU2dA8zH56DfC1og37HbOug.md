## Goal

G3 — `unix.gmtime` and `unix.localtime` share ONE C helper
(`LuaUnixTime`) that pushes 11 positional values on success while
their failure path pushes `nil, error, errno` — `mon`/`mday` (slots
2/3) mean unrelated things depending on branch. The prior pass's fix
for this capture re-annotated the sharing as honest (matching how
`unix.nanosleep` was ALREADY annotated at that time); this repo has
since settled, with `unix.nanosleep` itself (`e028f15b2` #315) and
`unix.capget` (`8180f14b4` #309), that a real fix bundles the shared
success values into one table instead. This capture applies that to
both `gmtime` and `localtime` TOGETHER, because they share the one C
helper a table-bundling fix has to change: changing `LuaUnixTime` for
`gmtime` changes `localtime`'s runtime behavior in the same commit
whether or not `localtime`'s own `definitions.lua` entry is touched,
so both annotations move here, together, per AGENTS.md's
same-commit rule ("an annotation that deviates is a bug ... a
contract change to conform is made deliberately, definitions.lua same
commit"). The sibling capture `3IjRasyoYAsJxkJsQIBK9EPn3GK`
(`localtime`) is narrowed to test-only and BLOCKED BY this one — see
its own spec.

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c:2828-2864`:

```c
static dontinline int LuaUnixTime(lua_State *L, const char *call,
                                  struct tm *f(const time_t *, struct tm *)) {
  int64_t ts;
  struct tm tm;
  int olderr = errno;
  ts = luaL_checkinteger(L, 1);
  if (f(&ts, &tm)) {
    lua_pushinteger(L, tm.tm_year + 1900);
    lua_pushinteger(L, tm.tm_mon + 1);  // 1 ≤ mon  ≤ 12
    lua_pushinteger(L, tm.tm_mday);     // 1 ≤ mday ≤ 31
    lua_pushinteger(L, tm.tm_hour);     // 0 ≤ hour ≤ 23
    lua_pushinteger(L, tm.tm_min);      // 0 ≤ min  ≤ 59
    lua_pushinteger(L, tm.tm_sec);      // 0 ≤ sec  ≤ 60
    lua_pushinteger(L, tm.tm_gmtoff);   // ±93600 seconds
    lua_pushinteger(L, tm.tm_wday);     // 0 ≤ wday ≤ 6
    lua_pushinteger(L, tm.tm_yday);     // 0 ≤ yday ≤ 365
    lua_pushinteger(L, tm.tm_isdst);    // daylight savings
    lua_pushstring(L, tm.tm_zone);
    return 11;
  } else {
    return LuaUnixSysretErrno(L, call, olderr);
  }
}

static int LuaUnixGmtime(lua_State *L) {
  return LuaUnixTime(L, "gmtime", gmtime_r);
}

static int LuaUnixLocaltime(lua_State *L) {
  return LuaUnixTime(L, "localtime", localtime_r);
}
```

The annotations (`tool/net/definitions.lua:7117-7135` for `gmtime`,
`7137-7184` for `localtime`) are IDENTICAL in return shape:

```
---@param unixts integer
---@return integer|nil year nil when the call failed
---@return integer|string mon 1 ≤ mon ≤ 12, or the error string when the
--- call failed — failure returns exactly `nil, error, errno`, so its two
--- values land in the slots mon and mday occupy on success, not in slots
--- of their own past `zone`
---@return integer|unix.Errno mday 1 ≤ mday ≤ 31, or the errno when the
--- call failed
---@return integer hour 0 ≤ hour ≤ 23
---@return integer min 0 ≤ min ≤ 59
---@return integer sec 0 ≤ sec ≤ 60
---@return integer gmtoffsec ±93600 seconds
---@return integer wday 0 ≤ wday ≤ 6
---@return integer yday 0 ≤ yday ≤ 365
---@return integer dst 1 if daylight savings, 0 if not, -1 if unknown
---@return string zone
function unix.gmtime(unixts) end / function unix.localtime(unixts) end
```

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.gmtime(9223372036854775807))'
nil	gmtime: EOVERFLOW: Overflow error	75
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.localtime(9223372036854775807))'
nil	localtime: EOVERFLOW: Overflow error	75
```

(3 values each: `year` nil as declared, `mon` holds the error STRING,
`mday` holds errno `75` (`unix.EOVERFLOW`) — identical shape for both
bindings, since both call the same C helper.)

Cosmic-side spend:

- `grep -n 'unix.gmtime' cosmic/time.tl` → `cosmic/time.tl:127-132`,
  `local year, mon, mday, ... = unix.gmtime(unixts) if year == nil
  then ... return nil, errno.format(mon as string, "gmtime") end`.
- `grep -n 'unix.localtime' cosmic/time.tl` → `cosmic/time.tl:157-162`,
  the identical shape, `errno.format(mon as string, "localtime")`.

Both wrappers destructure all 11 positional values today and MUST be
rewritten to read one table's fields once this capture (and its
sibling test-only capture for `localtime`) lands — see Non-goals.

## Change

1. `third_party/lua/cosmo/lunix.c`, the SHARED `LuaUnixTime` helper:
   replace the 11-value positional push with one table, changing
   `gmtime` and `localtime` together:

   ```c
   static dontinline int LuaUnixTime(lua_State *L, const char *call,
                                     struct tm *f(const time_t *, struct tm *)) {
     int64_t ts;
     struct tm tm;
     int olderr = errno;
     ts = luaL_checkinteger(L, 1);
     if (f(&ts, &tm)) {
       lua_newtable(L);
       lua_pushinteger(L, tm.tm_year + 1900); lua_setfield(L, -2, "year");
       lua_pushinteger(L, tm.tm_mon + 1);     lua_setfield(L, -2, "mon");
       lua_pushinteger(L, tm.tm_mday);        lua_setfield(L, -2, "mday");
       lua_pushinteger(L, tm.tm_hour);        lua_setfield(L, -2, "hour");
       lua_pushinteger(L, tm.tm_min);         lua_setfield(L, -2, "min");
       lua_pushinteger(L, tm.tm_sec);         lua_setfield(L, -2, "sec");
       lua_pushinteger(L, tm.tm_gmtoff);      lua_setfield(L, -2, "gmtoffsec");
       lua_pushinteger(L, tm.tm_wday);        lua_setfield(L, -2, "wday");
       lua_pushinteger(L, tm.tm_yday);        lua_setfield(L, -2, "yday");
       lua_pushinteger(L, tm.tm_isdst);       lua_setfield(L, -2, "dst");
       lua_pushstring(L, tm.tm_zone);         lua_setfield(L, -2, "zone");
       return 1;
     } else {
       return LuaUnixSysretErrno(L, call, olderr);
     }
   }
   ```

   `LuaUnixGmtime`/`LuaUnixLocaltime` themselves (lines 2855-2864) are
   unchanged — both already just forward to this helper.

2. `tool/net/definitions.lua`, same commit — ONE new shared class, and
   BOTH `gmtime`'s and `localtime`'s return blocks rewritten to it:

   ```
   --- Broken-down time returned by `gmtime`/`localtime`.
   ---@class unix.BrokenDownTime
   ---@field year integer
   ---@field mon integer 1 ≤ mon ≤ 12
   ---@field mday integer 1 ≤ mday ≤ 31
   ---@field hour integer 0 ≤ hour ≤ 23
   ---@field min integer 0 ≤ min ≤ 59
   ---@field sec integer 0 ≤ sec ≤ 60
   ---@field gmtoffsec integer ±93600 seconds
   ---@field wday integer 0 ≤ wday ≤ 6
   ---@field yday integer 0 ≤ yday ≤ 365
   ---@field dst integer 1 if daylight savings, 0 if not, -1 if unknown
   ---@field zone string
   ```

   `unix.gmtime`'s block becomes:
   ```
   ---@param unixts integer
   ---@return unix.BrokenDownTime|nil
   ---@return string? error
   ---@return unix.Errno? errno
   ---@nodiscard
   function unix.gmtime(unixts) end
   ```

   `unix.localtime`'s block becomes the same shape, minus
   `---@nodiscard` (the original didn't have it either) — keep all of
   `localtime`'s existing prose (the timezone-database list, the `TZ`
   note) unchanged, only its `---@param`/`---@return` lines move.

3. `tool/lua/test_unix_misc.lua`: rewrite the existing `gmtime`
   success block (currently lines 36-44) to the new table shape, and
   add a failure-shape assertion:

   ```lua
   -- gmtime: success returns one table (tool/net/definitions.lua).
   local bdt = assert(unix.gmtime(1657297063))
   assert(bdt.year == 2022 and bdt.mon == 7 and bdt.mday == 8
     and bdt.hour == 16 and bdt.min == 17 and bdt.sec == 43
     and bdt.gmtoffsec == 0 and bdt.wday == 5 and bdt.yday == 188
     and bdt.dst == 0 and bdt.zone == "UTC")

   -- gmtime's one reachable failure (EOVERFLOW) is a clean nil, string,
   -- errno tuple now — nothing shares a slot with a BrokenDownTime field.
   local goy, gerr, geno = unix.gmtime(9223372036854775807)
   assert(goy == nil, "gmtime of an unrepresentable timestamp must report nil")
   assert(type(gerr) == "string", "the error must be a string")
   assert(geno == unix.EOVERFLOW, "errno must be EOVERFLOW")
   ```

## Non-goals

- No change to `LuaUnixGmtime`/`LuaUnixLocaltime` themselves (lines
  2855-2864) — both are one-line forwarders to `LuaUnixTime` already
  and need no edit.
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `localtime` reads the
  `TZ` environment variable and the on-disk zoneinfo database, so
  neither binding is the "zero-risk... no side effects" set that file
  scopes itself to.
- **Cosmic-side edit required, but not by this capture.** This is a
  BEHAVIOR change for BOTH bindings: `cosmic/time.tl:127-132`
  (`gmtime`) and `:157-162` (`localtime`) both break the moment this
  lands. Retiring both destructurings for `.year`/`.mon`/... field
  access is the sibling consumption slice, BLOCKED on this capture
  landing — do not fold it into this diff, and do not bump the cosmos
  pin here.
- `localtime`'s OWN test coverage (it has none today) is the sibling
  capture `3IjRasyoYAsJxkJsQIBK9EPn3GK`, not this one — this capture's
  `tool/lua/test_unix_misc.lua` work touches only the existing
  `gmtime` block.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix")
  local t=assert(u.gmtime(1657297063)) assert(t.year==2022 and t.zone=="UTC")
  local bad,e,en=u.gmtime(9223372036854775807) assert(bad==nil)
  assert(type(e)=="string") assert(en==u.EOVERFLOW)
  local lt=assert(u.localtime(1657297063)) assert(type(lt.year)=="number")'`
  exits 0.
- `grep -c '^---@class unix.BrokenDownTime' tool/net/definitions.lua`
  reports 1 (today 0).
- `grep -A3 '^function unix.gmtime' tool/net/definitions.lua | grep -c
  'integer|string mon'` reports 0 (today 1, in the paragraph above the
  function — confirms the old positional annotation is gone).
- `grep -A3 '^function unix.localtime' tool/net/definitions.lua |
  grep -c 'integer|string mon'` reports 0 (same check for the sibling
  binding, since both move together).

## Enablement

none needed beyond the note above: this capture necessarily changes
`localtime`'s annotation too (shared C helper), so land it before or
together with `3IjRasyoYAsJxkJsQIBK9EPn3GK`. Independent of
`3IjRZi3mc1TW31yGcE7e615d4Lc` and `3IjRa88PfMHXoRab5q1vZjeIuTa`
(disjoint files/blocks) and of the raise/sigprocmask captures.
