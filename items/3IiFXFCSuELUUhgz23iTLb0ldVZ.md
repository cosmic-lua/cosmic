## Goal

G3, cosmo-contracts: `unix.setfsuid` and `unix.setfsgid` declare
`true|nil, string?, unix.Errno?`, but the wrapper cannot observe the one
failure a correct caller — a privilege-drop that lacks permission to
touch fsuid/fsgid — will actually meet at runtime. The binding reports
`true` regardless. This is not a documentation looseness to tighten; it
is a runtime correctness gap in a security-sensitive operation.

## Evidence

- C source: `third_party/lua/cosmo/lunix.c:1537-1541` (`LuaUnixSetid`
  helper, shared by `setuid`/`setgid`/`setfsuid`/`setfsgid`), its two
  relevant callers at `1560-1562` (`LuaUnixSetfsuid`) and `1567-1569`
  (`LuaUnixSetfsgid`), and the shared `SysretBool` at `240-249` which
  treats any `rc != -1` as success.
- `tool/net/definitions.lua:5656-5661` (`setfsuid`) and `5663-5668`
  (`setfsgid`) — both `@return true|nil` / `@return string? error` /
  `@return unix.Errno? errno`.
- `setfsuid(2)`/`setfsgid(2)` (upstream Linux man pages — not in this
  repo) are documented as unable to signal failure via return value:
  success returns the *previous* fsuid/fsgid, failure returns the
  *current* (unchanged) one — neither is `-1` in ordinary operation.
- Probe (from the cosmopolitan repo root, built binary
  `o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e '
  local unix = require("unix")
  local pid = unix.fork()
  if pid == 0 then
    unix.setuid(65534)
    local ok, err, errno = unix.setfsuid(0)
    io.stderr:write("setfsuid(0) as unpriv: ok=", tostring(ok), " err=", tostring(err), " errno=", tostring(errno), "\n")
    local f = io.open("/proc/self/status")
    for line in f:lines() do if line:match("^Uid:") then io.stderr:write(line, "\n") end end
    os.exit(0)
  else unix.wait(pid) end'
  W...lunix.c:242:...] syscall supposed to return 0 / -1 but got 65534
  setfsuid(0) as unpriv: ok=true err=nil errno=nil
  Uid:	65534	65534	65534	65534
  ```
  The kernel refused the change (fsuid — the 4th `Uid:` field — stayed
  `65534`, never became `0`), yet the binding reported `true`. The
  build's own `SysretBool` `WARNF` sanity check (SYSDEBUG builds) already
  flags that this call violates the helper's `0`/`-1` assumption. The
  analogous `setfsgid` probe (drop to uid 65534, attempt
  `unix.setfsgid(0)`, inspect `/proc/self/status`'s `Gid:` line) shows
  the same non-signaling behavior.
- Cosmic-side spend: `grep -rn 'unix\.setfsuid\|unix\.setfsgid' cosmic/`
  → no hits for either binding — unwrapped in cosmic today, so nothing
  downstream currently trusts the false `true`. `cosmic/quicksand/proc.tl`'s
  `drop_privs` already does the analogous `setresuid`/`setresgid`/`capset`
  privilege-drop sequence and is the natural place a `setfsuid`/`setfsgid`
  wrapper would land — a wrapper built on today's binding would silently
  believe a failed fsuid/fsgid drop had succeeded.

## Change

Do **not** simply remove `|nil` from these two bindings' declared type
— that would encode "always succeeds," which the probe above proves
false for the case that matters. Instead fix `LuaUnixSetid`'s failure
detection for these two calls: read back the resulting fsuid/fsgid (no
direct `getfsuid(2)` exists; the established idiom is calling
`setfsuid(-1)`/`setfsgid(-1)` immediately after, which changes nothing
and returns the current value) and treat "requested id was not applied"
as failure, routing it through `LuaUnixSysretErrno` with a synthesized
`EPERM` so the Lua-level contract (`true|nil, err:string, errno?`) is
honestly satisfiable. Land the fix and a regression probe (the
transcript above, turned into an assertion) in the same commit as any
`definitions.lua` text change.

## Non-goals

- No change to `setuid`, `setgid`, `setresuid`, `setresgid`, or
  `capset` — this slice's probes confirm all five already return `-1`
  correctly on failure.
- No bundling with the `capget` tuple-deviation capture or the
  `getpgrp` raise capture.

## Acceptance

- A probe demonstrating a refused fsuid (and, separately, fsgid) change
  now returns `nil, err, errno` instead of `true`, for both bindings.
- `make -j$(nproc) o//tool/lua/test` passes.
- The PR description explicitly states why raising the type alone was
  rejected, citing this capture's probe.
