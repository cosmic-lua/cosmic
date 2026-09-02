## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#354 (item 3Il1RfbQ,
the ftrace function floor). `tool/lua/test_unix_misc.lua` forks a
child that calls `unix.pledge("")` (no `stdio`) and then
`unix.exit(42)`. Under `o//tool/lua/lua.dbg --ftrace`, the child's own
trace write after the pledge is a violation: the child dies of SIGSYS
(reproduced 2026-09-02: `WIFSIGNALED`, signal 31) and the parent's
assertion at line 69 fails. The plain `.ok` run passes. The function
floor therefore skips this test, so `lunix.c` functions only it
reaches (`LuaUnixPledge` and the child-side paths) are absent from the
committed floor. Re-measure at pull time: `o//tool/lua/lua.dbg
--ftrace tool/lua/test_unix_misc.lua 2>/dev/null; echo $?`.

## Change

Make the test's pledge case survive tracing without weakening what it
asserts: either the child pledges with `stdio` retained when tracing
is on (detectable via the `--ftrace` flag's environment or a
`unix.getenv` the harness sets), or the pledge case moves into a
separate script the floor collector runs untraced while the rest of
`test_unix_misc.lua` is traced. Then remove the entry from the
collector's `SKIP` table and rebaseline the floor
(`COVERAGE_BASELINE=1`), so the gained functions ratchet in.

## Non-goals

- No change to `unix.pledge` semantics; the SIGSYS is correct
  behaviour for a traced write under a pledge without `stdio`.
- No weakening of the assertion at line 69.
