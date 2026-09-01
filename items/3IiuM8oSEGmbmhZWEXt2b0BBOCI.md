## Goal

`getopt.parse` is a raise-candidate (G3, cosmo-contracts,
`path.join(nil)` class): every reachable nil branch rejects an
argument shape no correct caller passes, never a runtime/data
condition. Its contract should say so — raise (`luaL_argerror`/
`luaL_error`) instead of a fallible `nil, err` return, matching the
binding-contract rule already settled for other C bindings here
(argument-shape errors raise; data/environment failures return the
fallible tuple).

## Evidence

- C source: `tool/net/lgetopt.c:59-251` (`LuaGetoptParse`). Every one
  of its 11 `FAIL(...)` call sites checks the function's OWN argument
  types/sizes before `getopt_long()` is ever invoked:
  - `lgetopt.c:71` — `args` not a table
  - `lgetopt.c:73` — `optstring` not a string
  - `lgetopt.c:75` — `longopts` not nil/table
  - `lgetopt.c:81` — `args` table exceeds `MAX_ARGC` (10000)
  - `lgetopt.c:86` — `longopts` table exceeds `MAX_LONGOPTS` (1000)
  - `lgetopt.c:93` — a `longopts[i]` entry is not a table
  - `lgetopt.c:96` — a `longopts[i][1]` (name) is not a string
  - `lgetopt.c:100` — a `longopts[i][2]` (has_arg) is not a string
  - `lgetopt.c:102` — a `longopts[i][2]` is not `"none"`/`"required"`/`"optional"`
  - `lgetopt.c:106` — a `longopts[i][3]` (short) is not a string/nil
  - `lgetopt.c:115` — an `args[i]` is not a string
  None of these is a `getopt_long()` runtime outcome (unknown option,
  missing argument) — those are reported through the *success* path's
  `result.unknown`/`result.missing` fields (`lgetopt.c:194-233`), not
  through the fallible `nil, err` slot at all.
- `tool/net/definitions.lua:1629-1634`.
- Probe (from the cosmopolitan repo root, against
  `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); print(getopt.parse("not-a-table", "h"))'
  nil	args must be a table
  $ o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); print(getopt.parse({}, 42))'
  nil	optstring must be a string
  $ o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); print(getopt.parse({42}, "h"))'
  nil	args[1] must be a string
  $ o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); local r=getopt.parse({"-h"}, "h"); print(r.opts[1].opt)'
  h
  ```
- cosmic-side spend (`grep -n 'cosmo_getopt.parse\|getopt.parse' cosmic/flags/*.tl`
  in a `cosmic-lua/cosmic` checkout): `cosmic/flags/getopt.tl:91-94`
  and `cosmic/flags/parse.tl:117-120` both defensively guard
  `if not res/r0 then return nil, err end`, but by construction
  (`args` is always the process's own `{string}` argv, `optstring`
  always builds from typed `Flag` records, `longopts` always builds
  from typed `LongOpt` records) neither call site can actually hit
  this branch — dead-but-defensive code, the signature of a
  degenerate-only contract.

## Change

Raise (`luaL_argerror` for the per-argument-shape checks,
`luaL_error` for the size-limit checks) instead of returning
`nil, err` for all 11 branches above; update
`definitions.lua:1632-1634`'s `@return` to drop the `|nil`/`?nil`,
making `getopt.parse` return `getopt.Result` unconditionally (dropping
slot 2 entirely, since `getopt_long()` itself never fails — its
outcomes are `result.unknown`/`result.missing`). Update the binding
contract rule's precedent list if one is tracked.

## Non-goals

- No change to how unknown/missing options are reported
  (`result.unknown`/`result.missing` stay as-is — they are not this
  binding's nil path).
- No change to `re.*`/`argon2.*` bindings (separate captures/rows).
- No relaxing `MAX_ARGC`/`MAX_LONGOPTS` — those limits stay; only the
  channel they report through changes from a return value to a raise.

## Acceptance

- `getopt.parse`'s `definitions.lua` annotation declares
  `@return getopt.Result` (no `|nil`), no `@return string? error`.
- Every one of the 11 `FAIL(...)` sites raises instead of returning
  `nil, err`; `LuaGetoptParse`'s success path (`lgetopt.c:241-250`) is
  unconditional.
- `tool/net/test/tool/net/definitions_conformance` (or the
  `getopt`-covering test) still passes.
- `cosmic/flags/getopt.tl:91-94` and `cosmic/flags/parse.tl:117-120`'s
  `if not res/r0 then` guards become genuinely dead (or are removed) —
  filed as a follow-up on the cosmic side once this binding's contract
  lands, not part of this capture.
