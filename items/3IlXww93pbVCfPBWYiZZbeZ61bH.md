## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#354 (item 3Il1RfbQ,
the ftrace function floor). The three `tool/lua/test_definitions_*.lua`
scripts are pure-Lua source parsers over `tool/net/definitions.lua`;
under `--ftrace` every VM-internal C call is traced at about 28 MB/s.
Measured 2026-09-02: `test_definitions_conformance` wrote 25 GB of
trace without finishing (and filled the machine); all three passed
400 MB / 3.3M FUN lines within 15 s, where their plain runs take
seconds. The collector therefore skips all three (its `SKIP` table),
and `test_definitions_coverage` also probes 75 bindings by calling
them, so binding functions only that probe reaches are absent from
the committed floor. Re-measure at pull time: `o//tool/lua/lua.dbg
--ftrace tool/lua/test_definitions_coverage.lua 2>&1 >/dev/null |
head -c 400000000 | wc -l`.

## Change

Split the binding probes out of `test_definitions_coverage.lua` into
a small script the collector traces (each probe is one call per
binding, so its trace is bounded), leaving the parser-heavy checks in
the untraced script; or teach the collector to trace only the binding
entry points (ftrace has no filter, so this is the split). Remove the
three `SKIP` entries once the traced part is bounded, rebaseline the
floor, and record the floor delta in the PR.

## Non-goals

- No change to what the definitions checks assert.
- No ftrace filtering in the runtime.
