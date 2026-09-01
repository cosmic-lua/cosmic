## Goal

G3, cosmo-contracts: conform `unix.capget`'s return shape to the
`T|nil, err:string, errno?` invariant so a caller narrowing slot 1 does
not also need to know slots 2/3 mean different things on the two
branches — the `unix.nanosleep`/`remnanos` deviation, recurring here.

## Evidence

- C source: `third_party/lua/cosmo/lunix.c:1040-1057` (`LuaUnixCapget`)
  — success path pushes `effective, permitted, inheritable` and
  `return 3;`; failure path is `LuaUnixSysretErrno`, returning
  `nil, err:string, errno:int` (also 3 values).
- `tool/net/definitions.lua:7428-7435` —
  `@return integer|nil effective, integer permitted, integer inheritable`
  / `@return string? error` / `@return unix.Errno? errno`: 5 annotated
  returns describing what is actually a 3-value tuple.
- Probe (from the cosmopolitan repo root, built binary
  `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'print(require("unix").capget(999999))'
  nil	capget: ESRCH: No such process	3
  $ o//tool/lua/lua -e 'print(require("unix").capget())'
  8796092956671	8796092956671	0
  ```
  Both calls return exactly 3 values. Slot 2 is `permitted` on success
  and the error string on failure; slot 3 is `inheritable` on success
  and the numeric errno on failure — the same slot carries two
  unrelated meanings depending on branch.
- Cosmic-side spend: `grep -rn 'unix\.capget' cosmic/` → no hits;
  unwrapped today, so no existing wrapper masks or narrows this yet — a
  future wrapper is exactly where this would first bite (its sibling
  `cosmic/quicksand/caps.tl`/`proc.tl` already manipulate capability
  state via `prctl`/`capset` for sandbox privilege-dropping).

## Change

Pick one shape and make declaration and implementation agree:
(a) keep the 3-value success tuple but bundle it into one table return
(`{effective=…, permitted=…, inheritable=…}|nil, string?, unix.Errno?`)
so slots 2/3 always mean error/errno; or
(b) document today's positional sharing explicitly as a `@overload`
pair (the way `unix.fcntl` documents its multi-shape returns), rather
than as a linear `T|nil, err, errno?` — making clear this binding
is NOT expected to conform to the ordinary invariant.
Land whichever the goal owner picks as this item's convention, then
apply the same shape to no other binding without its own capture.

## Non-goals

- No change to `capset` — already a clean 3-slot `true|nil, string?,
  unix.Errno?`, confirmed by this slice's probe.
- No change to any other multi-return binding.

## Acceptance

- `capget`'s `definitions.lua` annotation and its C implementation's
  actual return arity/meaning agree at every call outcome.
- The PR includes a probe distinguishing the 3 success values from the
  3 failure values (the transcript above, turned into an assertion).
- `make -j$(nproc) o//tool/lua/test` passes.
