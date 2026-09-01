## Goal

G3, via the cosmo-contracts container: `unix.clearenv` stops declaring
`true|nil`. Like `unix.sigpending` (`NEW-1`), `clearenv` takes NO
argument at all, so there is no argument shape to misuse. This libc's
own `clearenv()` (`libc/intrin/clearenv.c`) unconditionally sets
`environ = 0` and returns `0` — there is no failure path in the
implementation to reach, documented or not. Annotation-tightening, not
an argument-validation raise.

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c:623-629`:

```c
// unix.clearenv()
//     ├─→ true
//     └─→ nil, error:str, errno:int
static int LuaUnixClearenv(lua_State *L) {
  int olderr = errno;
  return SysretBool(L, "clearenv", olderr, clearenv());
}
```

`libc/intrin/clearenv.c:22-31`, this project's own `clearenv()`:

```c
/**
 * Removes all environment variables.
 *
 * @return 0 on success, or nonzero on error
 */
int clearenv(void) {
  environ = 0;
  STRACE("clearenv() → 0");
  return 0;
}
```

There is no conditional in this function at all — it always returns
`0`. `SysretBool` (called by `LuaUnixClearenv`) treats any return
`!= -1` as success, so this binding cannot fail as long as this
`clearenv()` implementation stands.

The annotation (`tool/net/definitions.lua:4568-4576`):

```
--- Clears all environment variables.
---
--- This wraps the C `clearenv()` function to allow Lua scripts to remove
--- all environment variables at once.
---
---@return true|nil
---@return string? error
---@return unix.Errno? errno
function unix.clearenv() end
```

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.clearenv())'
true
```

Cosmic-side spend: `grep -rn 'unix\.clearenv' cosmic/` — no matches.
`clearenv` has no cosmic-side wrapper today, so this fix needs no
consumption slice.

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixClearenv`: drop the
   return-code check entirely — `clearenv()` has no failure path to
   check for:

   ```c
   // unix.clearenv()
   //     └─→ true
   static int LuaUnixClearenv(lua_State *L) {
     clearenv();
     lua_pushboolean(L, 1);
     return 1;
   }
   ```

2. `tool/net/definitions.lua`, same commit:

   ```
   --- Clears all environment variables.
   ---
   --- This wraps the C `clearenv()` function to allow Lua scripts to
   --- remove all environment variables at once. Never fails: this
   --- project's `clearenv()` (`libc/intrin/clearenv.c`)
   --- unconditionally sets `environ = 0` and returns success.
   ---@return true
   function unix.clearenv() end
   ```

3. `tool/lua/test_unix_misc.lua`: add, near the existing
   `unsetenv`/`setenv` coverage:

   ```lua
   -- clearenv has no reachable failure: this project's clearenv()
   -- (libc/intrin/clearenv.c) unconditionally succeeds.
   assert(unix.clearenv() == true, "clearenv must always return true")
   ```

## Non-goals

- No change to `libc/intrin/clearenv.c` — it is already unconditional;
  only the Lua binding's dead error path is removed.
- No cosmic-side edit — no caller exists (`grep -rn 'unix\.clearenv'
  cosmic/` is empty).
- No change to `unix.setenv`/`unix.unsetenv` — both keep real,
  reachable failures (EINVAL for a malformed name, ENOMEM) and stay
  class-3 exact as this item's summary table already has them.
- Placement caution: this test clears the WHOLE environment for the
  rest of the test process — place it late in
  `tool/lua/test_unix_misc.lua` (after any test that reads an
  environment variable), or scope it to a subprocess, so it cannot
  starve a later test of `PATH`/`TMPDIR`/etc.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix") assert(u.clearenv()==true)'`
  exits 0.
- `grep -B2 '^function unix.clearenv' tool/net/definitions.lua |
  grep -c nil` reports 0 (today 1: the `true|nil` line).

## Enablement

none needed. Independent of every other capture in this batch; the
placement caution above is the only real interaction to watch (with
whatever other `tool/lua/test_unix_misc.lua` tests exist at
implementation time).
