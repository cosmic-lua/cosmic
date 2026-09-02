## Goal

A ratcheted, per-file FUNCTION coverage floor for the Lua binding
sources (tool/net/l*.c, tool/lua/lcosmo.c, third_party/lua/cosmo/lunix.c),
computed from `--ftrace` logs of the existing tool/lua test scripts, so
a binding function the tests stop reaching fails `make o//tool/lua/test`.

## Evidence

Line-level gcov is not available (full record: item
3Il1RVDaKyr00zNMfdvnoW6jglZ `## Result`): cosmocc 14.1.0 instruments
(`__gcov0.*` counters, notes stamped `B41*`) but ships no libgcov and
no gcov tool (`ld.bfd: cannot find -lgcov`); the tree's
`libc/intrin/gcov.S` makes the runtime symbols weak no-ops so an
in-tree build links and writes nothing; the host gcc-13 libgcov links
(with a 5-symbol glibc shim), its ctor/dtor run under cosmo, but its
`gcov_info` layout differs (8 vs 9 `merge[]` slots — `n_functions` read
at +0x60, where gcc-14 objects hold 0) so it registers nothing, even
with the version word patched to `B33*`. `-fsanitize-coverage=
trace-pc-guard` is not a valid argument for this gcc.

The fallback is measured and works on the binary the test target
already builds. `o//tool/lua/lua.dbg --ftrace ft.lua 2> ft.log` on a
4-line script exercising cosmo.lsqlite3 and cosmo.cov, three runs:
31992 / 31980 / 32027 lines, 924 / 926 / 926 distinct `FUN` names; the
whole-log set difference between runs is exactly six allocator
internals (`__maps_add __maps_balloc __maps_compare __maps_free
__tree_insert prepend_alloc`); the per-binding-file covered set is
byte-identical across all three runs — 18 functions: 3 in lcov.c
(LuaCov LuaCovStart LuaCovStop), 15 in lsqlite3.c (cleanupdb closevms
create_meta db_close db_do_next_row db_exec db_gc db_next_named_row
db_nrows dbvm_gc lsqlite_do_open lsqlite_open_memory luaopen_lsqlite3
newvm vm_push_column). Whole-log counts are not a stable quantity;
the per-file SET is.

Log line: `FUN <pid> <tid> <ticks> <depth> <name>`; pid/tid carry ANSI
colour, `name` is the last whitespace field. Statics are named;
optimizer clones carry `.isra.N`/`.constprop.N`/`.part.N`
(`db_do_rows.isra.0`, `lsqlite_checkdb.constprop.0`). Name→file
mapping: `.cosmocc/current/bin/x86_64-linux-cosmo-nm -l --defined-only
o/$(MODE)/tool/lua/lua.dbg` (DWARF; note it prints lfuncs.c as
`<root>/./tool/net/lfuncs.c`, so normalize paths). Functions inlined
at -O2 never appear in a default-mode log; `MODE=dbg` (`-O0`,
ENABLE_FTRACE=1, build/config.mk:152-162) has no such hole.

Denominator measured on origin/master default mode: 545 T/t symbols
in 13 files — lunix.c 264, lsqlite3.c 105, lfuncs.c 66, lzip.c 39,
lfetch.c 13, llua.c 11, lcosmo.c 9, lcov.c 9, lpath.c 9, lre.c 9,
largon2.c 4, ljson.c 4, lgetopt.c 3; lfuncs3.c defines no function.
(lfuncs.c is linked via the TOOL_NET package though absent from
TOOL_LUA_LUA_MODULES, tool/lua/BUILD.mk:26-38; it counts.)

## Change

1. A collector script `tool/lua/coverage.lua` run by `lua.dbg` itself:
   for every `tool/lua/test_*.lua`, run
   `o/$(MODE)/tool/lua/lua.dbg --ftrace <test> 2> o/$(MODE)/tool/lua/<test>.ftrace`
   (keep exit status; the existing `.ok` rules stay the correctness
   gate), union the last field of every `FUN` line across logs,
   strip `\.(isra|constprop|part|cold)\.[0-9]+$` suffixes.
2. Denominator: `x86_64-linux-cosmo-nm -l --defined-only
   o/$(MODE)/tool/lua/lua.dbg`, keep `T`/`t` symbols whose file,
   normalized (strip `<root>/` and `./`), is one of the binding
   sources; per file, `defined` = that set, `covered` = defined ∩
   union-of-logs.
3. Floor file `tool/lua/coverage_floor.lua` — literal table
   `{ ["tool/net/lsqlite3.c"] = {defined=N, covered=M}, ... }`, one
   entry per binding file with at least one defined function (13 on
   origin/master), committed; first values are what step 2 measures
   at landing.
4. Gate: a new rule `o/$(MODE)/tool/lua/test_coverage.ok` in
   `tool/lua/BUILD.mk` (same `@touch $@` shape as the existing `.ok`
   rules, PR #351) that runs the collector and fails when any file's
   `covered` drops below the floor or a floor entry's file is missing;
   `o/$(MODE)/tool/lua/test` depends on it. A `COVERAGE_BASELINE=1`
   env rewrites the floor.
5. Measure wall-clock of the ftrace pass under `MODE=` and `MODE=dbg`
   and record both in the PR; pick `dbg` unless it exceeds 3x the
   plain test time, in which case default mode with the inlining
   caveat documented in the collector's header comment.

## Non-goals

- No line coverage, no `MODE=cov`, no change to `build/config.mk`,
  no touch of `libc/intrin/gcov.S` — the line-level route is
  3Il43qrU0v1rsyrdnssXqBUOjuH.
- No new binding, no change to any test's assertions; a test may be
  ADDED to raise a floor, never weakened.
- No per-line or per-branch counts from the ticks/depth columns; no
  whole-log function counts as a gated quantity.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` runs the coverage rule and passes
  on the landing commit; the floor file has one entry per binding
  file with a defined function (13 on origin/master; lfuncs3.c absent
  by construction) and the denominator totals 545 there.
- Deleting a binding test that is the only reach of some function
  (e.g. comment out `cov.start()` in tool/lua/test_cov.lua) turns the
  rule red naming file and function; restoring it turns it green.
- `COVERAGE_BASELINE=1 make o//tool/lua/test_coverage.ok` rewrites
  the floor and a following plain run passes.
- Stability is a SET claim, not a count claim: the per-file covered
  set is byte-identical across three consecutive runs of the whole
  collector (as measured for the 18-function probe set on
  origin/master), while whole-log lines and distinct names may move
  by allocator internals; the PR records the three-run comparison. A
  binding function that flips between runs is reported in the PR,
  not floored around.
- The PR body carries the per-file table (file, defined, covered) and
  the wall-clock numbers of step 5.
