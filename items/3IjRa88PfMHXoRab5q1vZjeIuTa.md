## Goal

G3 — `unix.setitimer`'s success path pushes 4 positional integers
(`intervalsec`, `intervalns`, `valuesec`, `valuens`) while its failure
path pushes `nil, error, errno` — the same slots mean unrelated things
depending on branch, and the current annotation declares
`intervalns`/`valuesec`/`valuens` as plain non-nilable `integer`,
which is false on the failure branch. Per the repo's now-settled
precedent (`e028f15b2` #315, `8180f14b4` #309 — see
`3IjRZi3mc1TW31yGcE7e615d4Lc`'s Evidence for both), the fix bundles the
shared success values into one table rather than merely re-annotating
the sharing.

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c:2770-2792`, `LuaUnixSetitimer`: on
success (`!setitimer(which, itptr, &oldit)`, line 2783) pushes 4
integers (lines 2784-2787). On failure (line 2790) calls
`LuaUnixSysretErrno(L, "setitimer", olderr)` — exactly 3 values: `nil,
error string, errno`.

The annotation (`tool/net/definitions.lua:6711-6720`):

```
---@param which integer
---@param intervalsec integer
---@param intervalns integer needs to be on the interval `[0,1000000000)`
---@param valuesec integer
---@param valuens integer needs to be on the interval `[0,1000000000)`
---@return integer|nil intervalsec, integer intervalns, integer valuesec, integer valuens
---@return string? error
---@return unix.Errno? errno
---@overload fun(which: integer): intervalsec: integer, intervalns: integer, valuesec: integer, valuens: integer
function unix.setitimer(which, intervalsec, intervalns, valuesec, valuens) end
```

`intervalns`/`valuesec`/`valuens` are declared plain `integer` — none
admits the string/errno `intervalns`/`valuesec` actually hold on
failure, and `valuens` is simply absent (never returned) on failure
though declared as always present.

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.setitimer(999))'
nil	setitimer: EINVAL: Invalid argument	22
```

(3 values: `intervalsec` nil as declared; `intervalns` holds the error
STRING; `valuesec` holds the errno integer `22`; `valuens` and the
declared `error`/`errno` slots are absent.)

Cosmic-side spend: `grep -n 'unix.setitimer' cosmic/signal.tl` →
`cosmic/signal.tl:201`, `local old_isec, old_ins, old_vsec, old_vns =
unix.setitimer(...)`, followed by (`cosmic/signal.tl:208-211`) `if
old_isec == nil then -- On failure the binding returns (nil, err,
errno): the error string -- arrives in the second slot. return nil,
errstr(old_ins, "setitimer") end` — a live wrapper coded against
exactly this undocumented sharing; it destructures 4 positional values
today and MUST be rewritten to read one table's fields once this
capture lands (see Non-goals).

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixSetitimer`: replace the
   4-value push (lines 2784-2787) with one table:

   ```c
   // unix.setitimer(which[, intervalsec, intns, valuesec, valuens])
   //     ├─→ previous:table
   //     └─→ nil, error:str, errno:int
   static int LuaUnixSetitimer(lua_State *L) {
     int which, olderr = errno;
     struct itimerval it, oldit, *itptr;
     which = luaL_checkinteger(L, 1);
     if (!lua_isnoneornil(L, 2)) {
       itptr = &it;
       it.it_interval.tv_sec = luaL_optinteger(L, 2, 0);
       it.it_interval.tv_usec = luaL_optinteger(L, 3, 0) / 1000;
       it.it_value.tv_sec = luaL_optinteger(L, 4, 0);
       it.it_value.tv_usec = luaL_optinteger(L, 5, 0) / 1000;
     } else {
       itptr = 0;
     }
     if (!setitimer(which, itptr, &oldit)) {
       lua_newtable(L);
       lua_pushinteger(L, oldit.it_interval.tv_sec);
       lua_setfield(L, -2, "intervalsec");
       lua_pushinteger(L, oldit.it_interval.tv_usec * 1000);
       lua_setfield(L, -2, "intervalns");
       lua_pushinteger(L, oldit.it_value.tv_sec);
       lua_setfield(L, -2, "valuesec");
       lua_pushinteger(L, oldit.it_value.tv_usec * 1000);
       lua_setfield(L, -2, "valuens");
       return 1;
     } else {
       return LuaUnixSysretErrno(L, "setitimer", olderr);
     }
   }
   ```

2. `tool/net/definitions.lua`, same commit:

   ```
   --- Previous interval-timer setting returned by `setitimer`.
   ---@class unix.Itimerval
   ---@field intervalsec integer
   ---@field intervalns integer
   ---@field valuesec integer
   ---@field valuens integer

   ---@param which integer
   ---@param intervalsec integer
   ---@param intervalns integer needs to be on the interval `[0,1000000000)`
   ---@param valuesec integer
   ---@param valuens integer needs to be on the interval `[0,1000000000)`
   ---@return unix.Itimerval|nil previous
   ---@return string? error
   ---@return unix.Errno? errno
   ---@overload fun(which: integer): unix.Itimerval
   function unix.setitimer(which, intervalsec, intervalns, valuesec, valuens) end
   ```

   (A flat 4-field table was chosen over nesting `interval`/`value`
   sub-tables — matching `unix.SleepRemainder`'s flat precedent and
   this binding's own already-flat argument list, so the migration on
   the cosmic side is a mechanical `.field` rewrite with no new nesting
   to reason about.)

3. `tool/lua/test_signal.lua`: add, before the trailing `print("PASS")`:

   ```lua
   -- setitimer now bundles its previous-value success fields into one
   -- table (tool/net/definitions.lua); pin both branches.
   local prev = assert(unix.setitimer(unix.ITIMER_REAL, 0, 0, 0, 0))
   assert(type(prev) == "table" and type(prev.intervalsec) == "number",
     "a successful setitimer must return one table")
   local bad, err, eno = unix.setitimer(999)
   assert(bad == nil, "setitimer(999) must report nil")
   assert(type(err) == "string", "the error must be a string, not a table field")
   assert(eno == unix.EINVAL, "errno must be EINVAL, not a table field")
   ```

## Non-goals

- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `setitimer` arms a
  real interval timer, so it is not the "zero-risk... no side
  effects" binding that file scopes itself to.
- **Cosmic-side edit required, but not by this capture.** This is a
  BEHAVIOR change: `cosmic/signal.tl:201`'s `local old_isec, old_ins,
  old_vsec, old_vns = unix.setitimer(...)` breaks the moment this
  lands. Retiring that destructuring for `previous.intervalsec` /
  `.intervalns` / `.valuesec` / `.valuens` is the sibling consumption
  slice, BLOCKED on this capture landing — do not fold it into this
  diff, and do not bump the cosmos pin here.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix")
  local p=assert(u.setitimer(u.ITIMER_REAL,0,0,0,0))
  assert(type(p)=="table") assert(type(p.intervalsec)=="number")
  local bad,e,en=u.setitimer(999) assert(bad==nil)
  assert(type(e)=="string") assert(en==u.EINVAL)'` exits 0.
- `grep -c '^---@class unix.Itimerval' tool/net/definitions.lua`
  reports 1 (today 0).
- `grep -c '^---@return integer|nil intervalsec, integer intervalns'
  tool/net/definitions.lua` reports 0 (today 1: the positional
  4-value return this change replaces).

## Enablement

none needed. Independent of `3IjRZi3mc1TW31yGcE7e615d4Lc` (sigaction,
different C function, different `definitions.lua` block) and of the
raise/sigprocmask captures. Both this capture and
`3IjRZi3mc1TW31yGcE7e615d4Lc` append to `tool/lua/test_signal.lua`, so
whichever merges second rebases a short append.
