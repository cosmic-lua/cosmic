## Goal

G3, via the cosmo-contracts container: `unix.clock_gettime` stops
declaring `integer|nil` for a failure only a wrong or exotic clock id
can produce. cosmic's five clock readers currently dispose of that
union with licensed asserts (cosmic PR #1385); exact returns make the
asserts deletable and the generated type plain.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `3c36bc35`.

`third_party/lua/lunix.c`, `LuaUnixGettime` (lines 1626–1637): success
pushes two integers; failure returns
`LuaUnixSysretErrno(L, "clock_gettime", olderr)` (line 1634) — the
`nil, err, errno` tuple. The clock id is read inline:
`luaL_optinteger(L, 1, CLOCK_REALTIME)` (line 1629).

The annotation (`tool/net/definitions.lua`, block ending line 5853):
`---@return integer|nil seconds, integer nanos` (5849),
`---@return string? error` (5850), `---@return unix.Errno? errno`
(5851). The prose already states the reachability classes:

- "This function only fails if `clock` is invalid." (line 5845)
- REALTIME, MONOTONIC, PROCESS_CPUTIME_ID, THREAD_CPUTIME_ID each
  carry "Cosmopoiltan guarantees this clock will never raise `EINVAL`"
  (lines 5781, 5793, 5837, 5841).
- The one PLATFORM-reachable failure with a valid constant:
  `CLOCK_REALTIME_COARSE` / `CLOCK_MONOTONIC_COARSE` "will raise an
  `EINVAL` error on extremely old Linux distros like RHEL5" (lines
  ~5820–5833). So the raise this slice introduces is reachable there —
  a feature-probe (`pcall`) case, not silent breakage; state it in the
  rewritten prose.

Callers: `grep -rn "clock_gettime" --include='*.lua' tool/ third_party/`
finds only `tool/lua/test_signal.lua:41` (`unix.clock_gettime()`,
no-arg — unaffected) and the annotation. Downstream, cosmic passes
only the two guaranteed constants (`cosmic/time.tl`, five sites) —
behaviorally invisible there; retiring its asserts is the sibling
consumption slice.

## Change

1. **`third_party/lua/lunix.c`**, `LuaUnixGettime`: hoist the clock id
   and raise the standard bad-argument error on failure:

   ```c
   static int LuaUnixGettime(lua_State *L) {
     struct timespec ts;
     int olderr = errno;
     int clock = luaL_optinteger(L, 1, CLOCK_REALTIME);
     if (!clock_gettime(clock, &ts)) {
       lua_pushinteger(L, ts.tv_sec);
       lua_pushinteger(L, ts.tv_nsec);
       return 2;
     }
     errno = olderr;
     return luaL_argerror(
         L, 1, lua_pushfstring(L, "invalid or unsupported clock id %d", clock));
   }
   ```

   (Restore `errno` before raising, as `LuaUnixSysretErrno` did.)

2. **`tool/net/definitions.lua`**, same commit: the return block
   (lines 5849–5851) becomes exactly
   `---@return integer seconds, integer nanos` — the error and errno
   return lines are deleted. Replace the prose lines 5843–5845
   ("Returns `EINVAL` if clock isn't supported on platform." / "This
   function only fails if `clock` is invalid.") with: "An invalid
   clock id, or one this platform cannot serve (the `_COARSE` clocks
   on extremely old Linux distros), raises a bad-argument error — wrap
   the call in `pcall` to feature-probe a nonstandard clock. The
   per-clock guarantees above name the clocks that can never fail."
   `---@nodiscard` stays.

3. **`tool/lua/test_definitions_conformance.lua`**: add
   `probe("unix.clock_gettime", unix.clock_gettime)` beside
   `probe("unix.getpid", ...)` (line 253) — the binding is
   side-effect-free, so it belongs in the probed set and now verifies
   two plain integer slots — and in the `=== failure shapes ===`
   section (line 372):

   ```lua
   assert(not pcall(unix.clock_gettime, -1),
     "clock_gettime of an invalid clock id must raise")
   ```

   No slot-observation entry is needed: the binding no longer declares
   an error slot.

## Non-goals

- Every other `lunix.c` binding keeps its contract. In particular
  `nanosleep` (EINTR is environmental; its slot-2 shape is the census
  sibling's subject), `gmtime`, `localtime`.
- No change to CLOCK_* constant registration (the magnum tables).
- No cosmic-side edit and no cosmos pin bump: the sibling consumption
  slice, blocked on this one.
- Do not fix the "Cosmopoiltan" typos in guarantee lines this diff
  does not already rewrite — surgical diffs, mergeable fork.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u = require("cosmo.unix") local s, ns = u.clock_gettime() assert(math.type(s) == "integer" and math.type(ns) == "integer") local m = u.clock_gettime(u.CLOCK_MONOTONIC) assert(math.type(m) == "integer") assert(not pcall(u.clock_gettime, -1))'`
  exits 0.
- `grep -B6 '^function unix.clock_gettime' tool/net/definitions.lua | grep -c 'nil'`
  reports 0 (today 3: the union slot, the error line, the errno line).

## Enablement

none needed. Independent of the sibling path.join slice; both touch
`definitions.lua` and the conformance file at distant anchors, so the
second to merge rebases — neither blocks the other.
