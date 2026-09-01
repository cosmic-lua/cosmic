## Goal
G3, via cosmo-contracts: close `unix.raise` to the argument-shape-raises
doctrine `unix.clock_gettime` already settled (#277) — its sole
reachable failure is an invalid signal number, not an environmental
condition, so it should raise via `luaL_argerror` instead of returning
`nil, error, errno`.

## Evidence
- C source, `third_party/lua/cosmo/lunix.c:1296-1299` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`):
  ```c
  static int LuaUnixRaise(lua_State *L) {
    int olderr = errno;
    return SysretInteger(L, "raise", olderr, raise(luaL_checkinteger(L, 1)));
  }
  ```
  `SysretInteger` (lunix.c:251-262) relays `raise()`'s C return value
  directly — success pushes the integer rc, failure calls
  `LuaUnixSysretErrno` (`nil, err:string, errno:int`). `raise()`'s own
  libc return is the only source of `nil`; there is no other branch.
- `tool/net/definitions.lua:5027-5034`:
  ```
  --- Triggers signal in current process.
  ---
  --- This is pretty much the same as `kill(getpid(), sig)`.
  ---@param sig integer
  ---@return integer|nil rc
  ---@return string? error
  ---@return unix.Errno? errno
  function unix.raise(sig) end
  ```
- POSIX (raise, IEEE Std 1003.1-2017) documents exactly one failure
  condition: `[EINVAL] The value of the sig argument is an invalid or
  unsupported signal number.` Unlike `kill()`/`killpg()`, `raise()`
  always targets the calling process — there is no ESRCH/EPERM path,
  because no external-process condition (existence, ownership) can ever
  be the cause.
- Probe, built via `make -j$(nproc) o//tool/lua/lua` at the commit above:
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; print(unix.raise(unix.SIGWINCH or 28))'
  0
  $ o//tool/lua/lua -e 'local unix=require"unix"; print(unix.raise(999))'
  nil	raise: EINVAL: Invalid argument	22
  ```
  The only way to reach the `nil` branch (per POSIX and per probing) is
  a signal number no correct caller constructs — real callers pass
  named constants (`unix.SIGTERM`, etc.), always valid.
- cosmic-side spend, `grep -rn 'unix\.raise' cosmic/` (checkout at
  `/home/user/cosmic`):
  ```
  cosmic/signal.tl:181:  local rc, err = unix.raise(sig)
  ```
  `cosmic/signal.tl`'s `raise()` wrapper narrows `rc == nil` into
  `false, errstr(err, "raise")` — ordinary fallible-effect handling,
  no special-casing for EINVAL. If the binding raises instead, this
  error path becomes dead and the wrapper can simplify to match
  `kill`/`killpg`'s shape.

## Change
Make `LuaUnixRaise` validate `sig` is a supported signal number and
raise via `luaL_argerror` before calling `raise()`, mirroring
`LuaUnixGettime`'s already-settled clock-id validation
(`lunix.c:1655-1670`, PR #277 — "The only failure is a clock id this
platform cannot serve, which is a bad argument rather than an
environmental condition."). Update `definitions.lua:5027-5034`'s
`@return` to drop `|nil` from `rc` and drop the trailing `string?`/
`unix.Errno?` lines, matching `clock_gettime`'s post-#277 shape. On the
cosmic side, regenerate `cosmo.d.tl`, then simplify `cosmic/signal.tl`'s
`raise()` wrapper (and its test) to the infallible-effect shape.

## Non-goals
- No change to `unix.kill`/`unix.killpg` — both have a genuine
  ESRCH/EPERM environmental failure independent of the signal-number
  question.
- No change to `unix.sigprocmask` — filed as its own capture for the
  same doctrine.

## Acceptance
- `LuaUnixRaise` raises `luaL_argerror` for an unsupported/invalid
  signal number instead of returning `nil, error, errno`.
- `definitions.lua`'s `unix.raise` annotation declares a non-nullable
  `integer` return.
- `make -j$(nproc) o//tool/lua/test` (binding tests + annotation
  coverage ratchet) passes.
- cosmic's generated `cosmo.d.tl` for `unix.raise` narrows to a single
  non-nullable `integer`, and `cosmic/signal.tl`'s wrapper (and its
  test) pass under `--make ci` after adjustment.
