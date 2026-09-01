## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s process lifecycle, exec and scheduling surface. A research slice: its deliverable is recorded evidence and the
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
nothing is silently dropped.

Re-measured 2026-09-01 at HEAD `fd0884d9` (two commits ahead of
`1e165815`: `8180f14b` unix.capget, `fd0884d9` unix.isatty — neither in
this slice's scope): totals are now 211 EXACT / 191 NIL / 38 NONE = 440.
The delta is fully accounted for by those two commits; re-running the
scope-filter below at HEAD still yields exactly this slice's 12
bindings, all still NIL. Not a bounce.

**This slice's scope: the 12 nil-admitting bindings below.**

```text
unix.fork unix.commandv unix.spawn unix.spawnp unix.wait
unix.daemon unix.nice unix.getpriority unix.setpriority
unix.getrusage unix.prctl unix.Memory:wait
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo cosmic-lua/cosmopolitan`.
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
"exact") back onto THIS item.

Note: several of these (`unix.fork`, `unix.wait`, `unix.spawn`) are
process-lifecycle primitives — probing them for real means actually
forking/waiting child processes; be careful your probes don't leave
orphaned processes or hang the sandbox (use short-lived children,
always reap with `wait`, add timeouts where relevant).

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

## Summary Table

Scope count: 12. Row count: 12 — match.

Read of the spec's three classes as applied here: none of this slice's
12 bindings is class-1 (nil reachable ONLY via a degenerate argument
shape) — every one has a genuine environmental or data-dependent
failure path a correct caller can hit. All 12 are therefore class-2;
within class-2 the disposition is either "tuple exact" (capture column
reads `exact`) or "tuple deviation" (needs its own capture). One
binding, `unix.wait`, has a deviation.

| # | Binding | Class | C source | definitions.lua | Probe (from cosmopolitan repo root, against `o//tool/lua/lua`) | Cosmic-side spend | Capture |
|---|---|---|---|---|---|---|---|
| 1 | `unix.fork` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:578-581` | `4655` | `o//tool/lua/lua -e 'local u=require("unix");local p=u.fork();if p==0 then u.exit(0) end;print(p);u.wait(p)'` — resource-exhaustion only (EAGAIN/ENOMEM); no argument to be degenerate | `cosmic/proc/init.tl:230`; `cosmic/child/init.tl:330`; `cosmic/quicksand/{proc.tl:245,proxy.tl:121,proxy/serve.tl:401,init.tl:119,box/run.tl:270,319}` — all narrow `pid == nil` | exact |
| 2 | `unix.commandv` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:859-874` | `4676` | `o//tool/lua/lua -e 'local u=require("unix");print(u.commandv("this-definitely-does-not-exist-xyz123"))'` → `nil  commandv: ENOENT: No such file or directory  2` (data-dependent: prog absent from PATH) | `cosmic/proc/init.tl:136`; `cosmic/child/init.tl:223` | exact |
| 3 | `unix.spawn` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:769-809` | `4795` | `o//tool/lua/lua -e 'local u=require("unix");print(u.spawn("/nonexistent/prog/xyz123",{"x"}))'` → `nil  spawn: ENOENT: No such file or directory  2`. See out-of-scope note: a malformed `argv`/`envp` element does not nil-return here — it crashes (`ConvertLuaArrayToStringList` frees uninitialized memory) — so the nil-admitting path is *purely* the environmental ENOENT case, strengthening class-2. This crash is filed separately as its own item. | `cosmic/child/fast.tl:109-111`; `cosmic/child/init.tl:298` | exact |
| 4 | `unix.spawnp` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:814-854` | `4810` | `o//tool/lua/lua -e 'local u=require("unix");print(u.spawnp("this-definitely-does-not-exist-xyz123",{"x"}))'` → `nil  spawnp: ENOENT: No such file or directory  2`. Same crash caveat as spawn applies (shared helper) | none found under `cosmic/` (unused by any wrapper today) | exact |
| 5 | `unix.wait` | 2, tuple DEVIATION | `third_party/lua/cosmo/lunix.c:1304-1316` | `4938` | `o//tool/lua/lua -e 'local u=require("unix");local wp,s2,s3=u.wait(99999);print(wp,s2,s3,u.ECHILD)'` → `nil  wait: ECHILD: No child process  10  10`; success case: `o//tool/lua/lua -e 'local u=require("unix");local p=u.fork();if p==0 then u.exit(3) end;local wp,ws,ru=u.wait(p);print(wp,type(ws),ws,type(ru))'` → `wpid  number  768  userdata` — slot2 is `wstatus:integer` on success vs. the error string on failure, slot3 is `rusage:userdata` on success vs. `errno` on failure: the nanosleep-shaped deviation | `cosmic/proc/init.tl:251-258` already documents and guards this exact deviation ("On failure the binding returns (nil, err, errno): the error string arrives in the second slot, where the status word would have been"); also consumed at `cosmic/quicksand/proc.tl:284,291`, `proxy.tl:75,84,95,169,174`, `proxy/serve.tl:383`, `init.tl:136`, `box/run.tl:343`, `child/io.tl:132,134`, `child/init.tl:161` | CAP-1 (filed as `unix.wait`'s own capture) |
| 6 | `unix.daemon` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:3028-3039` | `5585` | success: fork+daemon(true,true) → `true nil nil`; failure path is fork()/setsid()/chdir() failing inside `daemon(3)` — resource/environment-dependent, no argument shape (both args are `lua_toboolean`-coerced, never invalid) | `cosmic/proc/init.tl:106` | exact |
| 7 | `unix.nice` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:3044-3055` | `6779` | `o//tool/lua/lua -e 'local u=require("unix");local p=u.fork();if p==0 then u.setuid(1000);print(u.nice(-5));u.exit(0) end;u.wait(p)'` → `nil  nice: EACCES: Permission denied  13` (privilege-dependent); `unix.nice(-1)` as root returns `-1  nil  nil` (errno checked, not rc==-1) | `cosmic/proc/rusage.tl:75` | exact |
| 8 | `unix.getpriority` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:3065-3077` | `6804` | `o//tool/lua/lua -e 'local u=require("unix");print(u.getpriority(u.PRIO_PROCESS,999999))'` → `nil  getpriority: ESRCH: No such process  3` | `cosmic/proc/rusage.tl:88` | exact |
| 9 | `unix.setpriority` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:3087-3099` | `6824` | `o//tool/lua/lua -e 'local u=require("unix");print(u.setpriority(u.PRIO_PROCESS,999999,0))'` → `nil  setpriority: ESRCH: No such process  3` | `cosmic/proc/rusage.tl:102` | exact |
| 10 | `unix.getrusage` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1264-1273` | `6842` | `o//tool/lua/lua -e 'local u=require("unix");print(u.getrusage(99999))'` → `nil  getrusage: EINVAL: Invalid argument  22` | `cosmic/proc/rusage.tl:27`; `cosmic/instrument.tl:62,103` | exact |
| 11 | `unix.prctl` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1018-1026` | `7434` | `o//tool/lua/lua -e 'local u=require("unix");print(u.prctl(999999))'` → `nil  prctl: EINVAL: Invalid argument  22` (bad/unsupported `PR_*` option — data-dependent, also platform-dependent on non-Linux) | `cosmic/quicksand/proc.tl:45,49,73,78`; `cosmic/quicksand/caps.tl:77,109,126,168`; `cosmic/sandbox/landlock.tl:416` | exact |
| 12 | `unix.Memory:wait` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:3878-3915` | `7804` | `o//tool/lua/lua -e 'local u=require("unix");local m=u.mapshared(4096);m:store(0,5);print(m:wait(0,999))'` → `nil  futex_wait: EAGAIN: Resource temporarily unavailable  11`; timeout case similarly yields `ETIMEDOUT`. No argument-shape nil path — an out-of-range `expect`/nonzero-high-bits word throws, never nil-returns | `cosmic/shm.tl:223-258` (`mem:wait`) already pcall-guards and narrows exactly this tuple, with an explicit comment on the deviation-free shape and the EINTR-retry loop | exact |

Out-of-scope finding filed separately: a memory-corruption crash in
`ConvertLuaArrayToStringList` (shared by execve/execvp/execvpe/
fexecve/spawn/spawnp) — see row 3's note.
