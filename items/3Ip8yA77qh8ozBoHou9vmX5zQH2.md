## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`) and the
cosmopolitan checkout's `tool/net/definitions.lua`.

The annotation is already split upstream:

    grep -n -B7 "^function unix.bind" tool/net/definitions.lua
    6225:---@param fd integer
    6226:---@param ip? uint32
    6227:---@param port? uint16
    6228:---@return true|nil
    6229:---@return string? error
    6230:---@return unix.Errno? errno
    6231:---@overload fun(fd: integer, unixpath: string): true
    6232:function unix.bind(fd, ip, port) end

(`unix.connect` the same at 6615-6622; `unix.setsockopt`'s SO_LINGER
and TCP_SAVE_SYN arms at 6494-6495; `grep -c "@overload"` → 32.)
The generator drops it: `_types/gentype_parse.tl:413-419` reads an
`@overload` only when its return list starts with `nil` (the failure
fold, `gentype_render.tl:215-222`); a success arm "must not trigger"
(`:416`). The pinned `unix.d.tl` therefore carries one arm —
`bind: function(fd: integer, ip?: integer, port?: integer): boolean | nil, string, Errno`
— and every unix-path caller restates the signature:
`cosmic/net/socket.tl:334` (`unix.bind as function(number, string): (boolean, string)`),
`:397` (connect), `:437` (setsockopt timeval), `cosmic/net/connect.tl:95`.

Teal accepts a repeated function field as an overload set — probe,
pinned binary:

    local record U
      bind: function(fd: integer, ip?: integer, port?: integer): boolean | nil, string, integer
      bind: function(fd: integer, unixpath: string): boolean | nil, string, integer
    end
    local ok, err = u.bind(3, "/tmp/x"); local ok2, err2 = u.bind(3, 1, 2)
    → Type check passed

(the pinned `tl.d.tl` uses the same form: `tonumber: function(any): number`
beside `tonumber: function(any, integer): integer`).

## Change

- `_types/gentype_parse.tl`: keep the failure fold; additionally
  collect every `---@overload fun(<params>): <returns>` whose return
  list does not start with `nil` into an `overloads` list on the
  binding entry. A param spelled as a constant (`unix.SOL_SOCKET: integer`)
  is positional: keep only its type. A named return (`flags: integer`,
  `seconds: integer, enabled: boolean`) keeps only its type. An
  overload whose params or returns the existing type converter cannot
  render is skipped and counted; `_types/gentype_test.tl` asserts that
  count so a regression in coverage is visible.
- `_types/gentype_render.tl`: after the primary line emit one
  `name: function(<params>): <returns>` per collected overload. When
  the primary is fallible, append the same folded error tuple to the
  overload (`true` → `boolean | nil, string, Errno`): the C entry is
  one function (`third_party/lua/cosmo/lunix.c:2211`, `SysretBool`),
  so its failure shape is the primary's.
- `_types/gentype_test.tl`: a case feeding bind's block above and
  expecting two `bind:` lines; one for setsockopt's constant-typed
  params.
- `cosmic/net/socket.tl:334, 397, 437` and `cosmic/net/connect.tl:95`:
  delete the casts, call the binding directly.
- `_build/casts_baseline.tl`: `cosmic/net/socket.tl` 3 → gone,
  `cosmic/net/connect.tl` 1 → gone; reconcile
  `docs/design/cast-sites.tsv`. If `### function shape` has no rows
  left (the six other rows are `respec 6sv6`), delete that heading
  from `docs/design/casts.md` — whichever of the two lands second
  does it.
- Cold build: the consumer sites are checked in generation 1 against
  types the TREE's generator wrote (generators run before the graph),
  so no pin bump is expected; prove it with
  `rm -rf o && bin/cosmic --make fetch && bin/cosmic --make build`
  before opening the PR. `bin/cosmic --make ci` ends `ci: PASS`.

## Non-goals

The upstream overloads' `: true` return (no failure tuple) is a
`definitions.lua` defect — `bind-overload-error-tuple`, cosmopolitan
repo. This generator folds the tuple on regardless, so it is not
blocked on that.
