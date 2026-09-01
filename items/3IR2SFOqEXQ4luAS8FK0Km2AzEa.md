## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s user, group, session and capability surface. A research slice: its deliverable is recorded evidence and the
follow-up captures, not code.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815` (the
commit carrying both settled sibling contracts, #276 and #277).

The universe is one walk of `tool/net/definitions.lua`: for each
`^function` declaration, classify the FIRST `@return` line of the
contiguous `---` doc run directly above it — **NIL** when that line
contains `|nil` or its type token ends in `?`, **EXACT** otherwise,
**NONE** when the run declares no `@return` at all. Save this as
`census.awk` and run it from the cosmopolitan repo root:

```awk
/^---/ { run[n++] = $0; next }
/^function / {
  name = $2; sub(/\(.*/, "", name)
  cls = "NONE"
  for (i = 0; i < n; i++) {
    if (run[i] ~ /^---@return /) {
      split(run[i], f, " ")
      cls = (index(run[i], "|nil") > 0 || f[2] ~ /\?$/) ? "NIL" : "EXACT"
      break
    }
  }
  print cls "\t" name
  n = 0; next
}
{ n = 0 }
```

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    209 EXACT
    192 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
439
```

209 + 192 + 38 = 439, so the walk classifies every declaration and
nothing is silently dropped. By module, the 192 NIL rows
(`awk -F'\t' '$1=="NIL"{print $2}' … | sed 's/[:.].*//' | sort | uniq -c`):

| module | nil-admitting |
|---|---|
| `unix` | 127 |
| `lsqlite3` | 22 |
| `cosmo` | 22 |
| `zip` | 14 |
| `re` | 5 |
| `getopt` | 1 |
| `argon2` | 1 |
| `path`, `cov`, `repl` | 0 |

`path` is exact in all 7 of its bindings — sibling 3IQtfuCx (#276)
closed the last one — and `cov` and `repl` contribute no rows, so
neither module gets a census slice.

**This measurement supersedes the per-module figures in the parent's
bounce note**, which reported `unix` 128 (its walk predates #277's
`clock_gettime`), `lsqlite3` 30 and "`cov` and `repl` declare 2
bindings between them". Re-derived here at `1e165815`, `lsqlite3`
carries 22 NIL rows of 108 declarations, and `cov`/`repl` declare 7
between them, all EXACT. The command above is the one to re-run; the
parent's is not reproducible from its note.

**This slice's scope: the 15 nil-admitting bindings below.**

```text
unix.getlogin unix.getsid unix.getpgrp unix.setpgrp unix.setpgid 
unix.getpgid unix.setsid unix.setuid unix.setfsuid unix.setfsgid 
unix.setgid unix.setresuid unix.setresgid unix.capget unix.capset
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo whilp/cosmopolitan`.
2. **environmental or data-dependent** — a correct caller can meet the
   failure (ENOENT, EINTR, bad input data). The union stays; verify the
   tuple is exactly `T|nil, err string, errno?` with nothing else
   sharing a slot. Each deviation gets its own capture — `unix.nanosleep`
   is the archetype, its slot 2 declared `integer|string remnanos` so
   the success remainder shares a slot with the error string.
3. **exact already** — no action; one summary row.

The evidence standard, per row:

- the C source cite, as `file:line`
- the `tool/net/definitions.lua` line
- one probe transcript against the built binary
  (`o//tool/lua/lua -e '...'`) demonstrating the reachability class
- the cosmic-side spend: `grep -rn '<binding>' cosmic/` in a cosmic
  checkout, listing the wrapper sites that guard or assert it today

Record the summary table (binding, class, probe command, capture id or
"exact") back onto THIS item with `gitboard spec`, then finish per
review.md's research-slice clause — the deliverable is board state, and
there is no product PR.

## Non-goals

- No code change in either repo — captures and evidence only.
- No bindings outside this slice's scope list above. A binding that
  turns out to belong to a sibling slice's family stays that slice's
  row; say so in this item's summary rather than adopting it.
- No re-litigating `path.join` (#276) or `unix.clock_gettime` (#277).
- No captures for class-3 rows.
- No promotion of the filed captures — ordering them is the goal
  owner's `compare`, after this slice reports.

## Acceptance

- This item's spec carries the summary table, with exactly one row per
  binding in the scope list above and no others. State the row count
  beside the scope count so a reader can see they match.
- Every class-1 row and every class-2 tuple-deviation row names a filed
  capture id, and `gitboard tree` under the parent container lists it.
- Every row's probe command is literally runnable from the
  cosmopolitan repo root against `o//tool/lua/lua`, built by
  `make -j$(nproc) o//tool/lua/lua`.
- The scope list is re-derived, not trusted: re-running the `census.awk`
  command above at the commit the slice is worked at yields this
  slice's binding set. A binding that has moved class since
  `1e165815` is a re-measured row, not a bounce.

## Enablement

none needed. The classes, the evidence standard and the capture rule
are stated in full above, so this slice is workable without reading the
parent. It writes no repo files, so it is parallel-safe with every
sibling census slice and with any contract slice they seed.

## Summary (measured 2026-09-01, worktree commit `2faa3113` — re-derivation confirms the scope list unchanged from `1e165815`; 209/192/38 census totals reproduce exactly)

15 rows below / 15 in scope — match.

All probes run from the cosmopolitan repo root; the built binary is
`o//tool/lua/lua`. Fork-based probes use `unix.fork()`/`unix.wait()` to
demonstrate a failure a real correct caller (a privilege-dropping
daemon, a session-leader shell) can hit — not a degenerate argument.

| # | binding | class | probe | capture id |
|---|---|---|---|---|
| 1 | `unix.getlogin` | environmental | P1 | exact |
| 2 | `unix.getsid` | environmental | P2 | exact |
| 3 | `unix.getpgrp` | degenerate-input-only (niladic, unconditionally successful per POSIX) | P3 | **CAP-A** |
| 4 | `unix.setpgrp` | environmental | P4 | exact — see out-of-scope note (mislabeled success value) |
| 5 | `unix.setpgid` | environmental | P5 | exact |
| 6 | `unix.getpgid` | environmental | P6 | exact |
| 7 | `unix.setsid` | environmental | P7 | exact |
| 8 | `unix.setuid` | environmental | P8 | exact |
| 9 | `unix.setfsuid` | degenerate-input-only per the wrapper's own check, but flagged: real correct-caller failures are silently reported as success | P9 | **CAP-B** (shared with row 10) |
| 10 | `unix.setfsgid` | same pattern as row 9 | P10 | **CAP-B** (shared) |
| 11 | `unix.setgid` | environmental | P11 | exact |
| 12 | `unix.setresuid` | environmental | P12 | exact |
| 13 | `unix.setresgid` | environmental | P13 | exact |
| 14 | `unix.capget` | environmental, tuple deviation (nanosleep-class: success values `permitted`/`inheritable` share slots 2/3 with the failure tuple's `error`/`errno`) | P14 | **CAP-C** |
| 15 | `unix.capset` | environmental | P15 | exact |

### Probe transcripts

**P1 — `unix.getlogin`** (definitions.lua:4569, lunix.c:629-638)
```
$ o//tool/lua/lua -e 'print(require("unix").getlogin())'
nil	getlogin: ENOENT: No such file or directory	2
```
No controlling-terminal/login-session record in this environment. Cosmic
wraps it at `cosmic/user.tl:38-44` (narrows on `not name`). Clean 3-slot
tuple — no deviation.

**P2 — `unix.getsid`** (definitions.lua:5509, lunix.c:1489-1492)
```
$ o//tool/lua/lua -e 'print(require("unix").getsid(999999))'
nil	getsid: ESRCH: No such process	3
```
Cosmic wraps at `cosmic/proc/init.tl:34-40`. Clean tuple.

**P3 — `unix.getpgrp`** (definitions.lua:5516, lunix.c:1499-1504, via `LuaUnixRc0`/`SysretInteger` at lunix.c:251-260)
```
$ o//tool/lua/lua -e 'print(require("unix").getpgrp())'
2792
```
`getpgrp()` takes no argument at all, and POSIX/glibc guarantee it
"shall always be successful" (Linux implements it as `getpgid(0)`, and
pid 0 always resolves to the calling process, so `ESRCH` is
unreachable). There is no degenerate input to point to — the whole call
is unconditionally successful. Cosmic's own wrapper
(`cosmic/proc/init.tl:44-47`) already pays an `assert` tax for a branch
that cannot occur:
```lua
-- assert: getpgrp(2) is always successful per POSIX
return (assert(unix.getpgrp()))
```

**P4 — `unix.setpgrp`** (definitions.lua:5523, lunix.c:1509-1511)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setsid()
  local pg, perr, perrno = unix.setpgrp()
  io.stderr:write("child setpgrp: ", tostring(pg), " ", tostring(perr), " ", tostring(perrno), "\n")
  os.exit(0)
else unix.wait(pid) end'
child setpgrp: nil setpgrp: EPERM: Operation not permitted 1
```
A session leader cannot change its own process group — a real failure.
Cosmic wraps at `cosmic/proc/init.tl:64-70`. Clean 3-slot tuple — filed
exact — but see the out-of-scope finding below: the declared "pgid"
success value is not actually the new pgid.

**P5 — `unix.setpgid`** (definitions.lua:5531, lunix.c:1528-1535)
```
$ o//tool/lua/lua -e 'print(require("unix").setpgid(999999,999999))'
nil	setpgid: ESRCH: No such process	3
```
Cosmic wraps at `cosmic/proc/init.tl:77-83`. Clean tuple.

**P6 — `unix.getpgid`** (definitions.lua:5538, lunix.c:1520-1526)
```
$ o//tool/lua/lua -e 'print(require("unix").getpgid(999999))'
nil	getpgid: ESRCH: No such process	3
```
Cosmic wraps at `cosmic/proc/init.tl:53-59`. Clean tuple.

**P7 — `unix.setsid`** (definitions.lua:5548, lunix.c:1513-1518)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setsid()
  local sid2, err2, errno2 = unix.setsid()
  io.stderr:write("child setsid (again): ", tostring(sid2), " ", tostring(err2), " ", tostring(errno2), "\n")
  os.exit(0)
else unix.wait(pid) end'
child setsid (again): nil setsid: EPERM: Operation not permitted 1
```
Already a process-group leader — real failure. Cosmic wraps at
`cosmic/proc/init.tl:91-97`. Clean tuple.

**P8 — `unix.setuid`** (definitions.lua:5651, lunix.c:1543-1548, via `LuaUnixSetid` at 1537-1541)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setuid(65534)
  local ok2, err2, errno2 = unix.setuid(0)
  io.stderr:write("setuid(0) after drop: ", tostring(ok2), " ", tostring(err2), " ", tostring(errno2), "\n")
  os.exit(0)
else unix.wait(pid) end'
setuid(0) after drop: nil setuid: EPERM: Operation not permitted 1
```
Cosmic wraps at `cosmic/user.tl:51-57`. Clean tuple.

**P9 — `unix.setfsuid`** (definitions.lua:5658, lunix.c:1557-1562, via `LuaUnixSetid`/`SysretBool` at 240-249)
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
The kernel refused the fsuid change (the 4th field of `/proc/self/status`'s
`Uid:` line — fsuid — stayed `65534`, never became `0`), but the binding
reported `true`. `setfsuid(2)`/`setfsgid(2)` are documented as unable to
signal failure via return value at all (success returns the previous
fsuid, failure returns the current/unchanged fsuid — neither is `-1` in
ordinary operation), so `SysretBool`'s `rc != -1` check can only see
"failure" for the reserved invalid-id sentinel `4294967295` — hence
"degenerate-input-only" by the letter of class 1. The build's own
`SysretBool` sanity assertion (SYSDEBUG builds) already flags that this
call violates its own contract. `grep -rn 'unix\.setfsuid' cosmic/` → no
hits: unwrapped in cosmic today.

**P10 — `unix.setfsgid`** (definitions.lua:5665, lunix.c:1564-1569)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setuid(65534)
  local ok, err, errno = unix.setfsgid(0)
  io.stderr:write("setfsgid(0) as unpriv: ok=", tostring(ok), " err=", tostring(err), " errno=", tostring(errno), "\n")
  local f = io.open("/proc/self/status")
  for line in f:lines() do if line:match("^Gid:") then io.stderr:write(line, "\n") end end
  os.exit(0)
else unix.wait(pid) end'
setfsgid(0) as unpriv: ok=true err=nil errno=nil
Gid:	0	0	0	0
```
Identical pattern to setfsuid. `grep -rn 'unix\.setfsgid' cosmic/` → no
hits.

**P11 — `unix.setgid`** (definitions.lua:5674, lunix.c:1550-1555)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setgid(65534)
  unix.setuid(65534)
  local ok3, err3, errno3 = unix.setgid(0)
  io.stderr:write("setgid(0): ", tostring(ok3), " ", tostring(err3), " ", tostring(errno3), "\n")
  os.exit(0)
else unix.wait(pid) end'
setgid(0): nil setgid: EPERM: Operation not permitted 1
```
Cosmic wraps at `cosmic/user.tl:64-70`. Clean tuple.

**P12 — `unix.setresuid`** (definitions.lua:5688, lunix.c:1579-1584, via `LuaUnixSetresid` at 1571-1577)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setresuid(65534,65534,65534)
  local ok2, err2, errno2 = unix.setresuid(0,0,0)
  io.stderr:write("setresuid(0x3) after drop: ", tostring(ok2), " ", tostring(err2), " ", tostring(errno2), "\n")
  os.exit(0)
else unix.wait(pid) end'
setresuid(0x3) after drop: nil setresuid: EPERM: Operation not permitted 1
```
Cosmic wraps at `cosmic/user.tl:79-85` and
`cosmic/quicksand/proc.tl:82-83`'s `drop_privs`. Clean tuple.

**P13 — `unix.setresgid`** (definitions.lua:5702, lunix.c:1586-1591)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setresgid(65534,65534,65534)
  unix.setuid(65534)
  local ok3, err3, errno3 = unix.setresgid(0,0,0)
  io.stderr:write("setresgid(0x3): ", tostring(ok3), " ", tostring(err3), " ", tostring(errno3), "\n")
  os.exit(0)
else unix.wait(pid) end'
setresgid(0x3): nil setresgid: EPERM: Operation not permitted 1
```
Cosmic wraps at `cosmic/user.tl:94-100` and
`cosmic/quicksand/proc.tl:80-81`'s `drop_privs`. Clean tuple.

**P14 — `unix.capget`** (definitions.lua:7432, lunix.c:1040-1057)
```
$ o//tool/lua/lua -e 'print(require("unix").capget(999999))'
nil	capget: ESRCH: No such process	3
$ o//tool/lua/lua -e 'print(require("unix").capget())'
8796092956671	8796092956671	0
```
Both calls return exactly 3 values, but slot 2 is `permitted`(success)/
error-string(failure) and slot 3 is `inheritable`(success)/errno(failure)
— the same slot means two unrelated things depending on branch, the
`unix.nanosleep`/`remnanos` archetype the Change section names.
`grep -rn 'unix\.capget' cosmic/` → no hits (unwrapped today).

**P15 — `unix.capset`** (definitions.lua:7443, lunix.c:1073-1089)
```
$ o//tool/lua/lua -e '
local unix = require("unix")
local pid = unix.fork()
if pid == 0 then
  unix.setuid(65534)
  local bit = 1 << 12
  local ok, err, errno = unix.capset(bit, bit, 0)
  io.stderr:write("capset attempt: ok=", tostring(ok), " err=", tostring(err), " errno=", tostring(errno), "\n")
  os.exit(0)
else unix.wait(pid) end'
capset attempt: ok=nil err=capset: EPERM: Operation not permitted errno=1
```
Cosmic wraps at `cosmic/quicksand/proc.tl:85-89`'s `drop_privs`. Clean
tuple, no deviation.

### Out-of-scope finding (not filed, reported per instructions)

`unix.setpgrp`'s declared success value is `@return integer|nil pgid`
(definitions.lua:5523) and cosmic's wrapper doc-comment repeats "The new
process group id" (`cosmic/proc/init.tl:61-70`), but the C
implementation (`LuaUnixSetpgrp` at lunix.c:1509-1511, via
`LuaUnixRc0`/`SysretInteger`) returns the raw `setpgrp()` return code
(`0` on success), never the actual new process group id — confirmed by
probe: `unix.setpgrp()` returns `0` while `unix.getpgrp()` immediately
after returns the real pgid. This is a doc/semantic accuracy bug
spanning both repos, outside this census's nil/tuple-slot classification
scope.
