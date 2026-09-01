## Goal

G3, via the cosmo-contracts container: `unix.sigprocmask` stops
declaring `unix.Sigset|nil` for a failure only an invalid `how` can
produce. Linux's sigprocmask(2) documents exactly one failure
reachable from Lua — EINVAL for a `how` outside
`SIG_BLOCK`/`SIG_UNBLOCK`/`SIG_SETMASK` (its other failure, EFAULT,
needs an invalid pointer the Lua binding never constructs) —
structurally identical to the already-settled `unix.clock_gettime` fix
(#277, 3IQtg7Sm).

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c:2568-2581`:

```c
// unix.sigprocmask(how:int, newmask:unix.Sigset)
//     ├─→ oldmask:unix.Sigset
//     └─→ nil, error:str, errno:int
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

`how` reaches the kernel unchecked. Linux's `sigprocmask(2)` man page:
"EINVAL: The value specified in how was invalid." and "EFAULT: ... set
or oldset point outside the process's allocated address space" — the
latter is unreachable here since `oldmask` is a stack `sigset_t` and
`newmask` is a checked `unix.Sigset` userdata, never a raw pointer Lua
controls.

The annotation (`tool/net/definitions.lua:6544-6566`):

```
---@param how integer can be one of:
---
--- - `SIG_BLOCK`: applies `mask` to set of blocked signals using bitwise OR
--- - `SIG_UNBLOCK`: removes bits in `mask` from set of blocked signals
--- - `SIG_SETMASK`: replaces process signal mask with `mask`
---
---@param newmask unix.Sigset
---@return unix.Sigset|nil oldmask
---@return string? error
---@return unix.Errno? errno
function unix.sigprocmask(how, newmask) end
```

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.sigprocmask(999, unix.sigset()))'
nil	sigprocmask: EINVAL: Invalid argument	22
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.SIG_BLOCK, unix.SIG_UNBLOCK, unix.SIG_SETMASK)'
0	1	2
```

Cosmic-side spend: `grep -n 'unix.sigprocmask' cosmic/signal.tl` →
`cosmic/signal.tl:267`, `local old, err = unix.sigprocmask(how, set)`
— `how` is always one of the module's own named constants there,
never a raw integer from outside; the wrapper documents no reachable
failure for it.

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixSigprocmask`: validate
   `how` inline against the three named constants and raise on
   anything else:

   ```c
   // unix.sigprocmask(how:int, newmask:unix.Sigset)
   //     └─→ oldmask:unix.Sigset
   static int LuaUnixSigprocmask(lua_State *L) {
     sigset_t oldmask;
     int olderr = errno;
     int how = luaL_checkinteger(L, 1);
     if (how != SIG_BLOCK && how != SIG_UNBLOCK && how != SIG_SETMASK) {
       errno = olderr;
       return luaL_argerror(L, 1, lua_pushfstring(L, "invalid how %d", how));
     }
     sigprocmask(how, luaL_checkudata(L, 2, "unix.Sigset"), &oldmask);
     LuaPushSigset(L, oldmask);
     return 1;
   }
   ```

   (EFAULT is already unreachable per the Evidence above, so once
   `how` is validated the syscall cannot fail; the return-code check
   is dropped, matching `LuaUnixGettime`'s post-#277 shape.)

2. `tool/net/definitions.lua`, same commit — the return block becomes
   exactly `---@return unix.Sigset oldmask`, the error/errno lines
   deleted (the `how` prose above stays unchanged; it already
   enumerates the only three valid values):

   ```
   ---@param newmask unix.Sigset
   ---@return unix.Sigset oldmask
   function unix.sigprocmask(how, newmask) end
   ```

3. `tool/lua/test_signal.lua`: add beside the existing
   `unix.sigset`/`unix.sigprocmask` coverage:

   ```lua
   -- sigprocmask's only reachable failure is an invalid `how`;
   -- EFAULT needs a pointer this binding never constructs from Lua.
   assert(not pcall(unix.sigprocmask, 999, unix.sigset()),
     "sigprocmask of an invalid how must raise")
   ```

## Non-goals

- No change to `unix.sigaction` or `unix.setitimer` — the sibling
  class-2 tuple-deviation captures, filed separately (CAP-3, CAP-4).
- No change to `unix.sigset`/`unix.Sigset` construction or the
  `newmask` argument check (`luaL_checkudata`) — already a type-shape
  error, unrelated to this fix.
- No cosmic-side edit and no cosmos pin bump — the sibling consumption
  slice, blocked on this one landing.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix") local m=assert(u.sigprocmask(u.SIG_BLOCK,
  u.sigset())) assert(not pcall(u.sigprocmask, 999, u.sigset()))'`
  exits 0.
- `grep -B2 '^function unix.sigprocmask' tool/net/definitions.lua |
  grep -c nil` reports 0 (today 1).

## Enablement

none needed. Independent of CAP-1 (different C function, different
`definitions.lua` block); both append to `tool/lua/test_signal.lua`,
so whichever merges second rebases a two-line append.
