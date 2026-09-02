## Goal

A ratcheted, per-file FUNCTION coverage floor for the Lua binding
sources (tool/net/l*.c, tool/lua/lcosmo.c, third_party/lua/cosmo/lunix.c),
computed from `--ftrace` logs of the existing tool/lua test scripts, so
a binding function the tests stop reaching fails `make o//tool/lua/test`.

## Evidence

Line-level gcov is not available: cosmocc 14.1.0 instruments
(`-fprofile-arcs -ftest-coverage` emits `__gcov0.*` counters and
`.gcno` files stamped `B41*`) but ships no libgcov and no gcov tool
(`ld.bfd: cannot find -lgcov`); the tree's `libc/intrin/gcov.S` makes
the symbols weak no-ops so an in-tree build would link and write
nothing; the host gcc-13 libgcov links (with a 5-symbol glibc shim)
and its ctor/dtor run under cosmo, but its `gcov_version` check is
`B33*` (`cmpl $0x4233332a`) and it silently registers nothing.
`-fsanitize-coverage=trace-pc-guard` is not a valid argument for this
gcc (only trace-cmp, trace-pc). Full record: item
3Il1RVDaKyr00zNMfdvnoW6jglZ `## Result`.

The fallback is measured and works on the binary the test target
already builds: `o//tool/lua/lua.dbg --ftrace ft.lua 2> ftrace.log`
on a 4-line script exercising cosmo.lsqlite3 and cosmo.cov gives
32050 lines, 924 distinct functions, including statics
(`db_exec`, `LuaCovStart`, `lsqlite_open_memory`, `cleanupdb`) and
optimizer clones (`db_do_rows.isra.0`, `lsqlite_checkdb.constprop.0`).
Log line: `FUN <pid> <tid> <ticks> <depth> <name>`; pid/tid carry ANSI
colour, `name` is the last whitespace field. Name→file mapping is
available from DWARF in the same binary
(`.cosmocc/current/bin/x86_64-linux-cosmo-nm -l --defined-only
o/$(MODE)/tool/lua/lua.dbg`). Functions inlined at -O2 never appear in
a default-mode log; `MODE=dbg` (`-O0`, ENABLE_FTRACE=1,
build/config.mk:152-162) has no such hole.

Denominator set, the objects in TOOL_LUA_LUA_MODULES
(tool/lua/BUILD.mk:26-38) plus lunix.c: lunix.c 5190 lines,
lsqlite3.c 2880, lzip.c 2227, lfetch.c 1552, lfuncs.c 1317, llua.c 669,
ljson.c 649, lcosmo.c 373, largon2.c 306, lre.c 301, lgetopt.c 270,
lcov.c 269, lpath.c 173, lfuncs3.c 2.

## Change

1. A collector script `tool/lua/coverage.lua` run by `lua.dbg` itself:
   for every `tool/lua/test_*.lua`, run
   `o/$(MODE)/tool/lua/lua.dbg --ftrace <test> 2> o/$(MODE)/tool/lua/<test>.ftrace`
   (keep exit status; the existing `.ok` rules stay the correctness
   gate), union the last field of every `FUN` line across logs,
   strip `\.(isra|constprop|part|cold)\.[0-9]+$` suffixes.
2. Denominator: `x86_64-linux-cosmo-nm -l --defined-only
   o/$(MODE)/tool/lua/lua.dbg`, keep `T`/`t` symbols whose file is
   one of the fourteen binding sources; per file, `defined` = that
   set, `covered` = defined ∩ union-of-logs.
3. Floor file `tool/lua/coverage_floor.lua` — literal table
   `{ ["tool/net/lsqlite3.c"] = {defined=N, covered=M}, ... }`, one
   entry per binding file, committed; first values are what step 2
   measures on origin/master at landing.
4. Gate: a new rule `o/$(MODE)/tool/lua/test_coverage.ok` in
   `tool/lua/BUILD.mk` (same `@touch $@` shape as the 67 existing
   `.ok` rules, PR #351) that runs the collector and fails when any
   file's `covered` drops below the floor or a floor entry's file is
   missing; `o/$(MODE)/tool/lua/test` depends on it. A
   `COVERAGE_BASELINE=1` env rewrites the floor.
5. Measure wall-clock of the ftrace pass under `MODE=` and `MODE=dbg`
   and record both in the PR; pick `dbg` unless it exceeds 3x the
   plain test time, in which case default mode with the inlining
   caveat documented in the collector's header comment.

## Non-goals

- No line coverage, no `MODE=cov`, no change to `build/config.mk`,
  no touch of `libc/intrin/gcov.S` — the line-level route is its own
  item.
- No new binding, no change to any test's assertions; a test may be
  ADDED to raise a floor, never weakened.
- No per-line or per-branch counts from the ticks/depth columns.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` runs the coverage rule and passes
  on the landing commit; the floor file has exactly fourteen entries
  matching the denominator set above.
- Deleting a binding test that is the only reach of some function
  (e.g. comment out `cov.start()` in tool/lua/test_cov.lua) turns the
  rule red naming file and function; restoring it turns it green.
- `COVERAGE_BASELINE=1 make o//tool/lua/test_coverage.ok` rewrites
  the floor and a following plain run passes.
- Counts are the same across two consecutive runs (ftrace is
  deterministic per test; a flaky function must be reported, not
  floored around).
- The PR body carries the per-file table (file, defined, covered) and
  the wall-clock numbers of step 5.
