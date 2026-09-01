## Goal

G3, cosmo-contracts: close `unix.getpgrp`'s declared-vs-actual gap —
its type admits `nil` but the binding cannot produce it, the same
`path.join`-class tightening already done for #276/#277.

## Evidence

- C source: `third_party/lua/cosmo/lunix.c:1499-1504`
  (`LuaUnixGetpgrp` → `LuaUnixRc0(L, "getpgrp", getpgrp)`), and the
  shared `LuaUnixRc0`/`SysretInteger` helpers at lines 251-260 that
  treat `rc == -1` as the only failure signal.
- `tool/net/definitions.lua:5515-5520` (`@return integer|nil pgid`,
  `@return string? error`, `@return unix.Errno? errno`).
- Probe (from the cosmopolitan repo root, `make -j$(nproc) o//tool/lua/lua` built):
  ```
  $ o//tool/lua/lua -e 'print(require("unix").getpgrp())'
  2792
  ```
  `getpgrp()` takes no argument, and POSIX/glibc guarantee it "shall
  always be successful" — Linux implements it as `getpgid(0)`, and pid
  0 always resolves to the calling process, so `ESRCH` (the only error
  `getpgid` can return) is unreachable. There is no argument shape to
  vary at all.
- Cosmic-side spend: `grep -rn 'unix\.getpgrp' cosmic/` → one hit,
  `cosmic/proc/init.tl:44-47`, which already treats the call as
  infallible:
  ```lua
  -- assert: getpgrp(2) is always successful per POSIX
  return (assert(unix.getpgrp()))
  ```
  i.e. cosmic's wrapper independently reached this conclusion and pays
  an `assert` tax for a branch that cannot occur.

## Change

Retype `unix.getpgrp` in `tool/net/definitions.lua` from
`@return integer|nil pgid` (+ the `error`/`errno` lines) to a bare
`@return integer pgid`, dropping the failure-tuple lines entirely (no
reachable failure branch), following the `path.join` precedent (#276).
In a follow-up cosmic-side change (landed separately, per this repo's
own convention of never bundling a contract change with a wrapper
fix), update `cosmic/proc/init.tl`'s `getpgrp()` to drop the now-needless
`assert` once the type is a bare `integer`.

## Non-goals

- No change to `setpgrp`, `setpgid`, `getpgid`, `getsid`, or `setsid` —
  each has a real, demonstrated failure path (see sibling item
  `3IR2SFOqEXQ4luAS8FK0Km2AzEa`'s evidence).
- No change to any other niladic `unix.*` accessor outside `getpgrp`.

## Acceptance

- `tool/net/definitions.lua`'s `unix.getpgrp` `@return` carries no
  `|nil`/`?`; re-running `census.awk` reclassifies it `EXACT`.
- `make -j$(nproc) o//tool/lua/test` passes.
- (Follow-up, may be a separate PR) `cosmic/proc/init.tl`'s `getpgrp()`
  wrapper sheds its `assert`; `o/bin/cosmic --make ci` passes.
