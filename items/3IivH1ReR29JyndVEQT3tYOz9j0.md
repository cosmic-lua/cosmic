## Goal
G3, via cosmo-contracts: close `unix.sigprocmask` to the same
argument-shape-raises doctrine as `unix.clock_gettime` (#277) — its
only reachable failure is an invalid `how` value, not an environmental
condition.

## Evidence
- C source, `third_party/lua/cosmo/lunix.c:2566-2576` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`):
  ```c
  static int LuaUnixSigprocmask(lua_State *L) {
    sigset_t oldmask;
    int olderr = errno;
    if (!sigprocmask(luaL_checkinteger(L, 1),
                     luaL_checkudata(L, 2, "unix.Sigset"), &oldmask)) {
      LuaPushSigset(L, oldmask);
      return 1;
    } else {
      return LuaUnixSysretErrno(L, "sigprocmask", olderr);
    }
  }
  ```
- `tool/net/definitions.lua:6561-6565`:
  ```
  ---@param newmask unix.Sigset
  ---@return unix.Sigset|nil oldmask
  ---@return string? error
  ---@return unix.Errno? errno
  function unix.sigprocmask(how, newmask) end
  ```
- Linux `sigprocmask(2)`'s documented failures are exactly `EFAULT`
  (`set`/`oldset` outside the process's address space) and `EINVAL`
  (bad `how`). `EFAULT` is unreachable from Lua: the binding always
  passes `&oldmask`, a local on the C stack, and the `newmask` argument
  is a `luaL_checkudata`-validated `unix.Sigset` the binding itself
  allocated — never a caller-supplied raw pointer.
- Probe:
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; local s=unix.sigset(); print(unix.sigprocmask(unix.SIG_BLOCK, s))'
  unix.Sigset()
  $ o//tool/lua/lua -e 'local unix=require"unix"; local s=unix.sigset(); print(unix.sigprocmask(999, s))'
  nil	sigprocmask: EINVAL: Invalid argument	22
  ```
- cosmic-side spend, `grep -rn 'unix\.sigprocmask' cosmic/`:
  ```
  cosmic/signal.tl:267:  local old, err = unix.sigprocmask(how, set)
  ```
  Every internal call site passes one of the three named constants
  (`SIG_BLOCK`/`SIG_UNBLOCK`/`SIG_SETMASK`); the fallible-effect
  handling around it is dead weight if the binding raises instead.

## Change
Validate `how` is one of `SIG_BLOCK`/`SIG_UNBLOCK`/`SIG_SETMASK` before
calling `sigprocmask()`, raising `luaL_argerror` otherwise. Update
`definitions.lua:6561-6565` to drop `|nil` from `oldmask` and the
trailing error lines. Regenerate cosmic's `cosmo.d.tl` and simplify
`cosmic/signal.tl`'s `sigprocmask()` wrapper accordingly.

## Non-goals
- No change to `unix.raise` — filed separately.
- No change to `unix.sigaction`/`unix.sigpending` — their nil paths are
  handled in their own captures (sigaction) or the parent item's
  class-3 note (sigpending).

## Acceptance
- `LuaUnixSigprocmask` raises on an invalid `how` instead of returning
  `nil, error, errno`.
- `definitions.lua`'s annotation declares a non-nullable
  `unix.Sigset` return.
- `make -j$(nproc) o//tool/lua/test` passes.
- cosmic's regenerated type and `cosmic/signal.tl`'s wrapper (and test)
  pass under `--make ci`.
