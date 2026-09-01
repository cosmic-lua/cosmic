## Goal
G3, via cosmo-contracts: `unix.setitimer`'s failure tuple silently
reuses the success shape's `intervalns`/`valuesec` slots for the error
string and errno — same defect family as `unix.nanosleep`'s archetype
(board item `3IivGU58CJHrof9ObOc0YFjout2`), undeclared here. Blocked
on that item so the fix mechanism is decided once and applied
uniformly.

## Evidence
- C source, `third_party/lua/cosmo/lunix.c:2750-2772` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`).
  Success path (2763-2768) pushes 4 integers: `intervalsec`,
  `intervalns`, `valuesec`, `valuens`. Failure path (2769-2771):
  ```c
  } else {
    return LuaUnixSysretErrno(L, "setitimer", olderr);
  }
  ```
  — the standard 3-value `(nil, err:string, errno:int)` triple.
- `tool/net/definitions.lua:6692-6701`:
  ```
  ---@param intervalsec integer
  ---@param intervalns integer needs to be on the interval [0,1000000000)
  ---@param valuesec integer
  ---@param valuens integer needs to be on the interval [0,1000000000)
  ---@return integer|nil intervalsec, integer intervalns, integer valuesec, integer valuens
  ---@return string? error
  ---@return unix.Errno? errno
  ---@overload fun(which: integer): intervalsec: integer, intervalns: integer, valuesec: integer, valuens: integer
  function unix.setitimer(which, intervalsec, intervalns, valuesec, valuens) end
  ```
  `intervalns`/`valuesec`/`valuens` are declared plain `integer` —
  never admitting the string/errno that land in the first two of those
  slots on failure.
- Probe (invalid `which` — EINVAL):
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; local a,b,c,d=unix.setitimer(999); print("a=",a,"b=",b,"c=",c,"d=",d)'
  a=	nil	b=	setitimer: EINVAL: Invalid argument	c=	22	d=	nil
  ```
  `b` (the `intervalns` slot) is the error string, `c` (`valuesec`) is
  the errno, `d` (`valuens`) is simply absent.
- cosmic-side spend, `grep -rn 'unix\.setitimer' cosmic/`:
  ```
  cosmic/signal.tl:201:  local old_isec, old_ins, old_vsec, old_vns = unix.setitimer(
  ```
  and (around line 209-212) `if old_isec == nil then return nil,
  errstr(old_ins, "setitimer") end` — the wrapper already relies on the
  exact undeclared sharing this capture documents.

## Change
Apply the same fix mechanism board item `3IivGU58CJHrof9ObOc0YFjout2`
(the `unix.nanosleep` archetype capture) settles on. Once that item
resolves, either: annotate `intervalns` as `integer|string` and
`valuesec` as `integer|unix.Errno` (parallel to nanosleep's pre-fix
`remnanos`), or restructure the failure path with its own trailing
slots — whichever mechanism the archetype capture chooses. `valuens`
stays absent on failure regardless — document accordingly. Regenerate
`cosmo.d.tl`; confirm `cosmic/signal.tl`'s `setitimer()` wrapper either
stays sound or needs an explicit cast under the new shape.

## Non-goals
- Does not take a position on whether `setitimer`'s invalid-`which`
  EINVAL should itself become a raise (an enum-like argument, similar
  in shape to `raise`/`sigprocmask`'s candidates) — flagged as an open
  question for whoever picks this up, but this capture's evidence and
  acceptance are scoped to the tuple shape only.

## Acceptance
- `definitions.lua`'s `unix.setitimer` annotation's `intervalns`/
  `valuesec` slots admit the error string / errno on the documented
  failure path (or the failure path no longer overlaps them, per
  `3IivGU58CJHrof9ObOc0YFjout2`'s resolution).
- The probe above type-checks cleanly under the regenerated types.
- `make -j$(nproc) o//tool/lua/test` passes.
- `cosmic/signal.tl` (and its test) pass under `--make ci`.
