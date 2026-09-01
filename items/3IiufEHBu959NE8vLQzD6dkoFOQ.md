## Goal

Close one instance of G3's "boundary is exact" contract work: `unix.wait`'s
return tuple violates the canonical `T|nil, err string, errno?` shape that
every other environmental cosmo.unix binding in the process/scheduling
family (fork, commandv, spawn, spawnp, daemon, nice, getpriority,
setpriority, getrusage, prctl, Memory:wait) follows exactly. `unix.nanosleep`
is the sole prior instance of this deviation shape; this closes the sibling
case in the process-lifecycle family.

## Evidence

- C source: `third_party/lua/cosmo/lunix.c:1304-1316` (`LuaUnixWait`).
  On success it pushes 3 values (`pid`, `wstatus`, `rusage`) via
  `lua_pushinteger`/`lua_pushinteger`/`LuaPushRusage`; on failure it
  delegates to `LuaUnixSysretErrno` (lunix.c:219-235), which always pushes
  exactly `(nil, error:string, errno:integer)`.
- `tool/net/definitions.lua:4938`, doc block above it declares the shape
  as-is on two separate `@return` annotation lines:
  ```
  ---@param pid? integer
  ---@param options? integer
  ---@return integer|nil pid, integer wstatus, unix.Rusage rusage
  ---@return string? error
  ---@return unix.Errno? errno
  function unix.wait(pid, options) end
  ```
  — the first `@return` line itself declares 3 comma-joined return values
  (an unusual construct not used elsewhere in this family), then two more
  `@return` lines follow. There is no single canonical `T|nil, err, errno`
  reading of this.
- Probe transcripts (from the cosmopolitan repo root, against
  `o//tool/lua/lua` built by `make -j$(nproc) o//tool/lua/lua`):

  Success:
  ```
  $ o//tool/lua/lua -e 'local u=require("unix");local p=u.fork();if p==0 then u.exit(3) end;local wp,ws,ru=u.wait(p);print(wp,type(ws),ws,type(ru))'
  23285	number	768	userdata
  ```

  Failure (ECHILD — waiting on a pid that is not a child):
  ```
  $ o//tool/lua/lua -e 'local u=require("unix");local wp,s2,s3=u.wait(99999);print(wp,s2,s3,u.ECHILD)'
  nil	wait: ECHILD: No child process	10	10
  ```

  So slot 2 is `wstatus:integer` (always present) on success, and the
  error string on failure; slot 3 is `rusage:userdata` on success, and
  `errno:integer` on failure. Same arity (3) both ways, but the meaning
  of slots 2 and 3 flips with success/failure.

- cosmic-side spend (`grep -rn 'unix\.wait\b' cosmic/` in a cosmic
  checkout): `cosmic/proc/init.tl:251-258` already guards this precisely —
  ```
  local function wait(pid?: integer, wait_flags?: integer): WaitResult | nil, string
    local wpid, status, rusage = unix.wait(pid, wait_flags)
    if wpid == nil then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the status word would have been.
      return nil, errstr(status, "wait")
    end
    return {pid = wpid, status = status, rusage = rusage}
  end
  ```
  — proving the deviation is real, understood, and already worked around
  by hand at the one wrapper site that owns it; every other call site
  (`cosmic/quicksand/proc.tl:284,291`, `proxy.tl:75,84,95,169,174`,
  `proxy/serve.tl:383`, `init.tl:136`, `box/run.tl:343`, `child/io.tl:132,134`,
  `child/init.tl:161`) either goes through this wrapper or narrows on
  `wpid == nil`/`WNOHANG`'s `0` by hand, each restating the same reasoning.

## Change

Bring `unix.wait`'s declared and actual return shape to the canonical
`T|nil, err string, errno?` used by every sibling in this family. The
concrete fix is an implementation decision for whoever picks this up
(candidates: return a single record on success the way this repo's own
binding-contract rule already prefers for multi-field successes elsewhere,
or document the flip explicitly and leave the C behavior as-is) — this
capture's job is to state the deviation with evidence, not prescribe the
fix. Any contract change is bound by AGENTS.md's rule: `definitions.lua`
updated in the same commit as the C change, landed as its own PR, never
folded into unrelated work, with the matching cosmic-side type regen and
wrapper fix following as cosmic's own change.

## Non-goals

- No re-litigation of `unix.nanosleep` (the already-known sibling instance
  of this shape) or of `path.join`/`unix.clock_gettime` (#276/#277).
- No change to `unix.wait`'s semantics (WNOHANG, signal semantics, the
  `-1`/pid argument reading) — only the tuple shape is in scope.
- No touching any other binding in the census's process/scheduling slice —
  all 11 siblings were verified exact and carry no capture.

## Acceptance

- `definitions.lua`'s doc block for `unix.wait` states one coherent
  return contract (not two disjoint `@return` lines with a 3-tuple packed
  into the first).
- The C implementation (`LuaUnixWait`) either already matches that
  contract or is changed to, in the same commit as the annotation change.
- cosmic's generated `cosmo.unix.d.tl` reflects the new shape once this
  repo's pin is bumped, and `cosmic/proc/init.tl`'s `wait()` wrapper
  (and its narrowing comment at lines 251-258) is updated or removed if
  the new shape no longer needs the workaround — landed as cosmic's own
  follow-up PR, not folded into this repo's change.
- `make -j$(nproc) o//tool/lua/test` passes with the change.

## Enablement

None needed — the deviation, its evidence, and the cosmic-side spend are
stated in full above.
