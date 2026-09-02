## Change

Cosmopolitan PR(s), shaped by the feasibility slice's `## Result`
(this spec is re-cut from it before pull):

1. `build/config.mk`: a `MODE=cov` block (modelled on `dbg`) whose
   instrumentation flags apply only to `tool/net/l*.c`,
   `tool/lua/lcosmo.c` and `third_party/lua/cosmo/lunix.c` via their
   BUILD.mk overrides — every other object builds as in default mode.
2. `tool/lua/coverage_floor.lua` (or `.txt`): one row per instrumented
   file, `path covered total`, written by the tool, never by hand.
3. `tool/lua/test_c_coverage.lua`, enrolled in `tool/lua/BUILD.mk`
   with its own `@touch $@` and run only under `MODE=cov`: after the
   test target's scripts have run, read each file's coverage, fail
   naming every file whose covered count is below its floor (the same
   ratchet rule as cosmic's `_build/ratchet.tl`: a decline fails, a
   rise passes and is not rewritten), and rewrite the floor only when
   `COVERAGE_BASELINE=1` is set.
4. `.github/workflows/pr.yml`: one lane `make -j$(nproc) MODE=cov
   o/cov/tool/lua/test` beside the existing x86_64 lane.
5. `AGENTS.md` (this repo): one paragraph naming the mode, the floor
   file, and the baseline command, beside the existing gate line.

## Non-goals

- No test content changes to raise coverage; the first floor is what
  the tests already reach.
- No instrumentation of libc, the APE loader, or the Lua interpreter.

## Acceptance

- `make MODE=cov o/cov/tool/lua/test` green on master; lowering one
  floor row by hand and raising another shows the gate fails on the
  lowered file only; `COVERAGE_BASELINE=1` rewrites the file to the
  measured values and a second run is green.
- Default-mode `make o//tool/lua/test` is byte-for-byte unaffected
  (no instrumented object in `o//`).
