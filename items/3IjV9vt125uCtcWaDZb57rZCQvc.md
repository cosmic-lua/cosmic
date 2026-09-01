## Goal

G3, via the cosmo-contracts container: `unix.sigpending` stops
declaring `unix.Sigset|nil`. Unlike an ordinary class-1 raise
candidate (`path.join(nil)`, `unix.clock_gettime(-1)`,
`unix.raise(999)`), `sigpending` takes NO argument at all — there is
no argument shape a caller, correct or not, could get wrong. Its one
documented failure, EFAULT, needs an invalid pointer this binding
never constructs, and its only OTHER failure path (`ENOSYS`, in the
underlying `libc/calls/sigpending.c`) is dead on every platform this
project's own `AGENTS.md` lists as a target (Linux, macOS, Windows,
FreeBSD, OpenBSD, NetBSD — all six are named explicitly in that file's
own OS branches). The declared `nil` is not merely unlikely; it is
unreachable, full stop, so this is annotation-tightening rather than
an argument-validation raise (there is nothing to validate).

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c:2753-2765`:

```c
// unix.sigpending()
//     ├─→ mask:unix.Sigset
//     └─→ nil, error:str, errno:int
static int LuaUnixSigpending(lua_State *L) {
  sigset_t mask;
  int olderr = errno;
  if (!sigpending(&mask)) {
    LuaPushSigset(L, mask);
    return 1;
  } else {
    return LuaUnixSysretErrno(L, "sigpending", olderr);
  }
}
```

`sigpending()`'s own doc comment (`libc/calls/sigpending.c:31-39`):
"`@param pending is where the bitset of pending signals is returned,
which may not be null`", "`@return 0 on success, or -1 w/ errno`",
"`@raise EFAULT if pending points to invalid memory`". Its
implementation (lines 40-67):

```c
int sigpending(sigset_t *pending) {
  int rc;
  if (!pending) {
    rc = efault();
  } else if (IsLinux() || IsNetbsd() || IsOpenbsd() || IsFreebsd() || IsXnu()) {
    ...
    rc = 0;
  } else if (IsWindows()) {
    ...
    rc = 0;
  } else {
    rc = enosys();
  }
  ...
  return rc;
}
```

`pending` is always `&mask`, a valid local stack variable, from
`LuaUnixSigpending` — EFAULT is unreachable. The `else` (`ENOSYS`)
branch requires an OS that is none of Linux/NetBSD/OpenBSD/FreeBSD/XNU
(macOS)/Windows — exactly `AGENTS.md`'s six-platform support matrix,
with no seventh — so it, too, is dead on every platform this repo
ships. There is no reachable failure at all.

The annotation (`tool/net/definitions.lua:6684-6689`):

```
--- Returns the set of signals pending delivery to the calling process
--- that are currently blocked.
---@return unix.Sigset|nil mask
---@return string? error
---@return unix.Errno? errno
function unix.sigpending() end
```

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.sigpending())'
unix.Sigset()
```

Cosmic-side spend: `grep -rn 'unix\.sigpending' cosmic/` — no matches.
`sigpending` has no cosmic-side wrapper today, so this fix needs no
consumption slice.

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixSigpending`: drop the
   return-code check entirely — there is no reachable failure to
   check for:

   ```c
   // unix.sigpending()
   //     └─→ mask:unix.Sigset
   static int LuaUnixSigpending(lua_State *L) {
     sigset_t mask;
     sigpending(&mask);
     LuaPushSigset(L, mask);
     return 1;
   }
   ```

2. `tool/net/definitions.lua`, same commit:

   ```
   --- Returns the set of signals pending delivery to the calling
   --- process that are currently blocked. Never fails on any
   --- platform this project supports: its one documented failure,
   --- EFAULT, needs an invalid pointer this binding never
   --- constructs.
   ---@return unix.Sigset mask
   function unix.sigpending() end
   ```

3. `tool/lua/test_signal.lua`: add, before the trailing `print("PASS")`:

   ```lua
   -- sigpending takes no argument and has no reachable failure on any
   -- platform this project supports (EFAULT needs a pointer this
   -- binding never constructs); it must always return a plain Sigset.
   assert(unix.sigpending() ~= nil, "sigpending must always succeed")
   ```

## Non-goals

- No change to `libc/calls/sigpending.c` — its EFAULT/ENOSYS paths are
  correct for the general-purpose libc function; only the Lua binding,
  which never triggers either, is tightened here.
- No cosmic-side edit — no caller exists (`grep -rn
  'unix\.sigpending' cosmic/` is empty).
- No change to `unix.sigsuspend` or `unix.sigprocmask` — separate
  bindings, separate captures.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix") assert(u.sigpending()~=nil)'`
  exits 0.
- `grep -B2 '^function unix.sigpending' tool/net/definitions.lua |
  grep -c nil` reports 0 (today 1: the `unix.Sigset|nil mask` line).

## Enablement

none needed. Independent of every other capture in this batch; appends
one line to `tool/lua/test_signal.lua`.
