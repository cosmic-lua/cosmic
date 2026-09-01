## Goal
G3, via cosmo-contracts: `unix.sigaction`'s failure tuple silently
reuses the success shape's `flags`/`mask` slots for the error string
and errno — the same defect family as `unix.nanosleep`'s archetype
(board item `3IivGU58CJHrof9ObOc0YFjout2`), but undeclared here
(nanosleep at least types the shared slot honestly as a union; this
annotation does not). Blocked on that item so the fix mechanism is
decided once and applied uniformly.

## Evidence
- C source, `third_party/lua/cosmo/lunix.c:2642-2723` (measured at
  cosmic-lua/cosmopolitan master `fd0884d91eeaa2cd5659125282c1699e91bef715`).
  Success path (2695-2719) pushes 3 values: `oldhandler`,
  `oldsa.sa_flags`, `oldsa.sa_mask`. Failure path (2720-2722):
  ```c
  } else {
    return LuaUnixSysretErrno(L, "sigaction", olderr);
  }
  ```
  — the standard 3-value `(nil, err:string, errno:int)` triple, landing
  in the SAME three stack positions a caller destructures for success.
- `tool/net/definitions.lua:6639-6654`:
  ```
  ---@param mask? unix.Sigset
  ---@return function|integer|nil oldhandler, integer flags, unix.Sigset mask
  ---@return string? error
  ---@return unix.Errno? errno
  function unix.sigaction(sig, handler, flags, mask) end
  ```
  `flags` is declared plain `integer` — never admitting the string that
  actually lands there on failure.
- Probe (SIGKILL cannot be caught — EINVAL):
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix"; local a,b,c=unix.sigaction(unix.SIGKILL, unix.SIG_IGN); print("a=",a,"b=",b,"c=",c)'
  a=	nil	b=	sigaction: EINVAL: Invalid argument	c=	22
  ```
  Destructuring the full 3-name success shape puts the error string in
  `flags`'s slot and the errno in `mask`'s slot.
- cosmic-side spend, `grep -rn 'unix\.sigaction' cosmic/`:
  ```
  cosmic/signal.tl:252:  unix.sigaction(sig, raw_handler, flags, mask)
  ```
  and (around line 254-258) the wrapper destructures
  `prev, prev_flags, prev_mask = unix.sigaction(...)` and on
  `prev == nil` passes `prev_flags` straight to `errstr(...)` as the
  error string — already silently relying on the exact sharing this
  capture documents, with no cast because `errstr`'s parameter is
  permissive `any` (not because the type is honestly unioned).

## Change
Apply the same fix mechanism board item `3IivGU58CJHrof9ObOc0YFjout2`
(the `unix.nanosleep` archetype capture) settles on. Once that item
resolves, either: annotate `flags` as `integer|string` (parallel to
nanosleep's pre-fix `remnanos`) and `mask` as `unix.Sigset|unix.Errno`
if the archetype's resolution is "document the union honestly", or
restructure the failure path to use non-overlapping trailing slots if
the archetype's resolution is "give failure its own slots". Regenerate
`cosmo.d.tl` and confirm `cosmic/signal.tl`'s access to
`prev_flags`/`prev_mask` either stays sound or needs an explicit
narrowing cast under the new shape.

## Non-goals
- No change to sigaction's raise-on-invalid-signal-number path
  (`lunix.c:2648-2651` already raises via `luaL_argerror`) — this
  capture is only about the failure TUPLE, not `sig` validation.
- Does not re-litigate whether EINVAL-for-SIGKILL/SIGSTOP should
  itself become a raise instead of a returned failure — a program
  generically iterating all signal numbers can legitimately hit this,
  so it stays in the environmental/data-dependent bucket.

## Acceptance
- `definitions.lua`'s `unix.sigaction` annotation's `flags`/`mask`
  slots admit the error string / errno on the documented failure path
  (or the failure path no longer overlaps them at all, per whichever
  mechanism `3IivGU58CJHrof9ObOc0YFjout2` settles on).
- A probe destructuring the full success arity against a forced
  failure (as above) type-checks cleanly under the regenerated types
  with no unexplained `any`.
- `make -j$(nproc) o//tool/lua/test` passes.
- cosmic's `cosmic/signal.tl` (and its test) pass under `--make ci`
  after any needed cast/narrowing update.
