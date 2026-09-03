## Evidence

Measured 2026-09-03 in the cosmopolitan checkout.

    grep -n "@overload.*: *true$" tool/net/definitions.lua
    5326:---@overload fun(oldpath: string, newpath: string): true
    5338:---@overload fun(existingpath: string, newpath: string, flags?: integer): true
    5339:---@overload fun(existingpath: string, newpath: string, flags: integer, olddirfd: integer, newdirfd: integer): true
    5671:---@overload fun(fd: integer, unix.F_SETFD: integer, flags: integer): true
    5673:---@overload fun(fd: integer, unix.F_SETFL: integer, flags: integer): true
    5674:---@overload fun(fd: integer, unix.F_SETLK: integer, ...): true
    5675:---@overload fun(fd: integer, unix.F_SETLKW: integer, ...): true
    6231:---@overload fun(fd: integer, unixpath: string): true
    6494:---@overload fun(fd:integer, unix.SOL_SOCKET: integer, unix.SO_LINGER: integer, secs:integer, enabled:boolean): true
    6495:---@overload fun(serverfd:integer, unix.SOL_TCP: integer, unix.TCP_SAVE_SYN: integer, enabled:integer): true
    6621:---@overload fun(fd:integer, unixpath:string): true
    7292:---@overload fun(path: nil, permissions: nil): true

Each sits under a primary that declares `@return true|nil`,
`@return string? error`, `@return unix.Errno? errno` (bind: 6228-6230,
connect: 6618-6620, setsockopt: 6491-6493). The C entry is one
function per name — `unix.bind`'s unix-path branch ends in
`SysretBool` (`third_party/lua/cosmo/lunix.c:2211`) — so the overload
arm fails exactly as the primary does, and its declared `true` says it
cannot. AGENTS.md's rule: "When slot 1 of a declared return admits
nil, slot 2 is the error — an annotation that deviates is a bug".
Downstream, cosmic's generator folds the failure tuple only from a
`nil, …` overload (`_types/gentype_parse.tl:413-419`), so these arms
are dropped from the generated types entirely.

## Change

- `tool/net/definitions.lua`: for each line above whose C function
  returns through `SysretBool`/`SysretInteger`-style failure (confirm
  per binding in `third_party/lua/cosmo/lunix.c`; the twelve share
  five functions: rename/link overloads, fcntl, bind, setsockopt,
  connect, pledge), rewrite the arm's return list to the primary's
  shape, e.g. `---@overload fun(fd: integer, unixpath: string): true|nil, string?, unix.Errno?`.
  An arm whose C path genuinely cannot fail keeps `true` and gains a
  one-line comment saying why.
- `make -j$(nproc) o//tool/lua/test` passes (the annotation-coverage
  ratchet reads these lines).
- No C change, no contract change: the tuple shape is what the code
  already returns; only the annotation moves.

## Non-goals

No cosmic-side edit here; cosmic consumes it through a later cosmos
pin bump, which is gated on the adaptation pass item (`A3HK_gamw`).
The generator-side fix (`gentype-overloads`) does not wait on this.
