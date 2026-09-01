## Finding

`ConvertLuaArrayToStringList` (`third_party/lua/cosmo/lunix.c:318-344`)
frees uninitialized heap memory — a genuine memory-corruption bug,
reachable from pure Lua with no privilege required — when a caller
passes an `argv`/`envp` array containing any element that cannot
convert to a string. It backs 11 call sites across `unix.execve`,
`unix.execvp`, `unix.execvpe`, `unix.fexecve`, `unix.spawn`, and
`unix.spawnp` (both their `argv` and `envp` parameters).

## Symptom

```
$ o//tool/lua/lua -e 'local u=require("unix");print(u.spawn("/bin/true",{{}}))'
```
segfaults (exit 139) instead of returning `nil, err` or raising a
clean Lua error.

## Provenance

Surfaced 2026-09-01 while researching board item `3IR2SQaCFZX6EZSVQI7aPvfGezb`
(handle «aPvf_Gezb», "cosmopolitan census: unix process, exec and
scheduling"), which was classifying `unix.spawn`'s nil-reachability for
an unrelated contract-exactness census. Filed here as its own item per
that research item's own "if you notice a real defect outside this
item's scope... report it; the orchestrator files it" rule — this is a
crash, not a contract-shape question, and warrants its own priority
independent of that census.

## Evidence

- `ConvertLuaArrayToStringList` (`third_party/lua/cosmo/lunix.c:318-344`)
  allocates its `char**` output array via `LuaAlloc`/`LuaRealloc`,
  which does NOT zero-initialize the memory. Its element loop converts
  each Lua array entry to a string; when it hits an entry it cannot
  convert, it calls `FreeStringList(p)` (lunix.c:338) immediately —
  before the array has been NUL-terminated at the point of failure.
- `FreeStringList` (lunix.c:308-316) walks the array with
  `for (i = 0; p[i]; ++i) free(p[i])` — a NUL-terminated-array
  convention. Since the array was never terminated before the early
  free, this walk reads past the valid, converted prefix into
  uninitialized heap memory and calls `free()` on whatever garbage
  pointer values happen to be there.
- Reproduced under `gdb` against `o//tool/lua/lua.dbg`: the crash
  backtrace is `dlfree_rseq` ← `FreeStringList` (lunix.c:308-316) ←
  `ConvertLuaArrayToStringList` (lunix.c:318-344) ← `LuaUnixSpawn`
  (lunix.c:778).
- Call sites sharing this helper (`grep -n
  'ConvertLuaArrayToStringList' third_party/lua/cosmo/lunix.c`):
  `unix.execve`, `unix.execvp`, `unix.execvpe`, `unix.fexecve`,
  `unix.spawn`, `unix.spawnp` — each of the six is one bad element
  (a table, function, or other non-string-convertible value) away from
  the identical crash, in either its `argv` or `envp` array.
- cosmic-side spend (`grep -rn` for these bindings in a
  `cosmic-lua/cosmic` checkout): wrapper sites that build these arrays
  from caller-supplied data include `cosmic/child/fast.tl:109-111`,
  `cosmic/child/init.tl:189,199,210,221,298,393,396`, and
  `cosmic/quicksand/box/run.tl:184` — any of these paths that lets a
  non-string value reach the underlying binding's `argv`/`envp` hits
  this crash rather than a clean error.

## Change

To be scoped at refinement. Candidate directions:

- Zero-initialize the allocation (`calloc`-equivalent, or explicitly
  NUL-terminate the array immediately after allocation, before the
  conversion loop begins) so an early `FreeStringList` call is always
  safe regardless of where the loop stops.
- And/or NUL-terminate the array up to the failed index before calling
  `FreeStringList`, so it only ever walks the valid, already-converted
  prefix.
- Either fix should convert this crash into the clean `luaL_argerror`
  (an argument-shape violation — a non-string element in an argv/envp
  array is exactly the "degenerate input no correct program passes"
  class this repo's own binding-contract rule already routes through
  `luaL_argerror`, not a silent crash or a fallible-tuple return).

## Non-goals

- Not a contract-shape/return-tuple question — this is a memory-safety
  crash, unrelated to the nil-admission census that surfaced it.
- Not touching the six bindings' other behavior (successful spawn/exec
  paths, environment handling on valid input) beyond the crash fix.

## Acceptance

- A regression test reproducing the crash on at least `unix.spawn`
  (the site this was found on) passes cleanly after the fix — i.e.
  `unix.spawn("/bin/true", {{}})` (or the equivalent for whichever
  binding the fix targets first) returns a clean `nil, err` or raises
  a `luaL_argerror`-style Lua error, never segfaults.
- `make -j$(nproc) o//tool/lua/test` passes.
- Ideally, a single fix in `ConvertLuaArrayToStringList` covers all 6
  affected bindings (execve, execvp, execvpe, fexecve, spawn, spawnp)
  since they share this one helper — verify at least one non-spawn
  call site (e.g. `unix.execve`) is also covered by the same fix or by
  its own regression probe.
