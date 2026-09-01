## Goal

G3, via the cosmo-contracts container: `unix.raise` stops declaring
`integer|nil` for a failure only an out-of-range signal number can
produce. POSIX's raise() has exactly one documented failure, EINVAL
for an invalid `sig`, structurally identical to the already-settled
`unix.clock_gettime` fix (#277, 3IQtg7Sm) whose shape this capture
reuses. An exact return retires the nil-check every caller of raise()
currently has to carry for a failure that only a wrong constant can
trigger.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c`, `LuaUnixRaise` (lines 1298-1304):

```c
// unix.raise(sig:int)
//     ├─→ rc:int
//     └─→ nil, error:str, errno:int
static int LuaUnixRaise(lua_State *L) {
  int olderr = errno;
  return SysretInteger(L, "raise", olderr, raise(luaL_checkinteger(L, 1)));
}
```

`raise()` itself (`libc/calls/raise.c:29-63`) documents `@raise EINVAL
if sig is invalid` and, on the Windows code path, enforces the exact
valid domain explicitly: `if (0 <= sig && sig <= 64)` (line 52) else
`einval()`. `unix.NSIG` is 64 (probed below), so the valid domain is
`0 <= sig <= NSIG`; `sig == 0` is a legitimate "no signal,
existence-check-only" call (mirroring `kill(pid, 0)`, already exact
per this item's row 1), not a degenerate input — it must stay valid.

The annotation (`tool/net/definitions.lua:5028-5035`):

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

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.raise(999))'
nil	raise: EINVAL: Invalid argument	22
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.NSIG)'
64
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.raise(0))'
0
```

(An invalid `sig` (999, outside `0..NSIG`) is the only reachable
failure; `sig == 0` succeeds, matching `raise()`'s own doc comment and
`kill`'s existence-check convention. CAUTION for whoever re-runs this:
do not probe `raise()` with a signal number in `1..NSIG` interactively
— several of them terminate the calling process by default, unlike
`999`/`0` above.)

Cosmic-side spend: `grep -n 'unix.raise' cosmic/signal.tl` →
`cosmic/signal.tl:181`, `local rc, err = unix.raise(sig)` — `sig`
there is always one of the module's own `Sigset`/`unix.SIG*` constants
passed through by the caller, never a raw untrusted integer; the
wrapper's own doc does not name a failure mode for `raise`, consistent
with the failure being unreachable through cosmic's public API.

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixRaise`: validate `sig`
   inline and raise a standard bad-argument error on failure,
   mirroring `LuaUnixGettime`'s post-#277 shape and
   `LuaUnixSigaction`'s existing `1 <= sig && sig <= NSIG` check
   (widened here to admit 0, raise's own valid existence-check value):

   ```c
   // unix.raise(sig:int)
   //     └─→ rc:int
   static int LuaUnixRaise(lua_State *L) {
     int olderr = errno;
     int sig = luaL_checkinteger(L, 1);
     if (!(0 <= sig && sig <= NSIG)) {
       errno = olderr;
       return luaL_argerror(
           L, 1, lua_pushfstring(L, "invalid signal number %d", sig));
     }
     lua_pushinteger(L, raise(sig));
     return 1;
   }
   ```

2. `tool/net/definitions.lua`, same commit — the return block (lines
   5032-5034) becomes exactly `---@return integer rc` and the
   error/errno lines are deleted; add one prose sentence:

   ```
   --- Triggers signal in current process.
   ---
   --- This is pretty much the same as `kill(getpid(), sig)`. Raises a
   --- bad-argument error if `sig` is not `0` (existence check only,
   --- like `kill(pid, 0)`) or a valid signal number — POSIX's only
   --- documented failure for `raise()`, `EINVAL`.
   ---@param sig integer
   ---@return integer rc
   function unix.raise(sig) end
   ```

3. `tool/lua/test_signal.lua`: add beside the existing
   sigaction/sigprocmask coverage:

   ```lua
   -- raise()'s only documented failure is an invalid signal number
   -- (EINVAL); sig == 0 is a legitimate existence-check call (like
   -- kill(pid, 0)) and must not raise.
   assert(not pcall(unix.raise, 999),
     "raise of an invalid signal number must raise")
   assert(unix.raise(0) == 0, "raise(0) is a valid existence check")
   ```

## Non-goals

- Every other `lunix.c` binding keeps its contract, including
  `unix.kill`/`unix.killpg` (already exact — ESRCH/EPERM are genuinely
  environmental there, per this item's rows 1-2) and
  `unix.sigprocmask` (the sibling class-1 capture, filed separately as
  `3IjRZ9hD9NrStsAnyhMzwK6ZzAh`).
- No change to `unix.sigaction`'s own inline `1 <= sig && sig <= NSIG`
  check (it correctly excludes 0, since installing a handler for "no
  signal" is meaningless) — `raise`'s domain is wider by exactly the
  value that makes it behave like `kill`.
- No cosmic-side edit and no cosmos pin bump — the sibling consumption
  slice, blocked on this one landing.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix") assert(u.raise(0)==0)
  assert(not pcall(u.raise,999)) assert(not pcall(u.raise,-1))'` exits
  0.
- `grep -B4 '^function unix.raise' tool/net/definitions.lua | grep -c
  nil` reports 0 (today 1: the `integer|nil rc` line).

## Enablement

none needed. Independent of every other capture in this batch (touches
only `LuaUnixRaise`, its own annotation block, and an appended block in
`tool/lua/test_signal.lua`); both this capture and `3IjRZ9hD9NrStsAnyhMzwK6ZzAh` append to
`tool/lua/test_signal.lua`, so whichever merges second rebases a
two-line append — neither blocks the other.
