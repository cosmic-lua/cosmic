## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`); probes run
under the pinned release (`o/bootstrap/cosmic`).

The class is 10 rows (`git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="function shape"'`):
`cosmic/net/socket.tl` 334, 397, 437 and `cosmic/net/connect.tl` 95 cast
around a binding overload the generated type lacks — those four are
the `gentype-overloads` item, not this one. The other six are not
bindings at all:

- `cosmic/quicksand/proxy.tl:143-145` — three function reads off a map
  view that exists only because `srv` stays `Server | nil` after a
  guard ending in `unix.exit(1)` (`proxy.tl:132-141`; the map view at
  141 is the `record union after guard` row). A guard that RETURNS
  narrows — probe, pinned binary:
  `local s, e = mk(); if not s then io.stderr:write("x") return nil, e end; local p = s.port(); return p`
  → `Type check passed`.
- `cosmic/coverage/init.tl:173` — `debug.sethook as function()` to
  call it with no arguments; the stdlib declaration wants 2–4
  (`debug.sethook()` → `wrong number of arguments (given 0, expects at least 2 …)`),
  but `debug.sethook(nil, "")` → `Type check passed`, and a nil hook
  turns the hook off (Lua 5.4 `db_sethook`: `lua_isnoneornil` → `func = NULL`).
- `cosmic/check_assertions_test.tl:341` — `pcall(f as function(): any)`
  where `f: function()`; `pcall(f)` alone fails
  (`did not produce an initial value for variable 'e'`), while
  `pcall(function(): any f() return nil end)` → `Type check passed`.
- `cosmic/quicksand/init.tl:73` — `fn as function(any, any): any ...`
  with `fn: any` (line 71): the operand is `any`, so under
  `docs/design/cast-legality.md`'s rule it is a legal cast; it IS the
  runtime-capability-probe shape (`cosmic/_probe.tl`), misfiled.

## Change

- `cosmic/quicksand/proxy.tl`: in `start` (`:113`, returns
  `ProxyHandle | nil, string`), after `unix.exit(1)` at `:137` add
  `return nil, tostring(nerr)` with a comment that the line is
  unreachable and exists to narrow `srv`. Delete the comment block and
  the four casts at `:138-145`; read `listen`, `port`, `serve_forever`
  off `srv` as `serve.Server` declares them
  (`git grep -n "record Server" origin/main -- cosmic/quicksand/proxy/`
  — field closures, called without `self`, as the current code does).
- `cosmic/coverage/init.tl:173-174`: `debug.sethook(nil, "")`, one
  comment: nil hook clears the hook.
- `cosmic/check_assertions_test.tl:341`: the wrapper form above.
- `cosmic/quicksand/init.tl:73`: keep the cast; reason becomes
  `-- cast: runtime capability probe: fn is any, an arbitrary binding`;
  in `docs/design/cast-sites.tsv` change that row's class to
  `runtime capability probe` by hand (reconcile carries class by
  path+line, it never rewrites one), then run
  `bin/cosmic --make run _build/cast_sites.tl --reconcile` and confirm
  it reproduces the file.
- `_build/casts_baseline.tl`: `cosmic/quicksand/proxy.tl` 5 → 1,
  `cosmic/coverage/init.tl` 5 → 4, `cosmic/check_assertions_test.tl`
  3 → 2 (`bin/cosmic --make run _build/casts.tl --baseline`).
- `docs/design/casts.md` `### function shape`: rewrite the verdict to
  name the residual four as the generator's dropped success overload
  (see `gentype-overloads`); `### record union after guard` drops the
  proxy exemplar if it cites `:141`
  (`git grep -n "proxy.tl:14" origin/main -- docs/design/casts.md`).
- `bin/cosmic --make ci` ends `ci: PASS`.

## Non-goals

`socket.tl` 334/397/437 and `connect.tl:95` — closed by
`gentype-overloads`; no `definitions.lua` change here.
