## Evidence

Found by the fresh-context review of cosmic-lua/cosmopolitan#354
(item 3Il1RfbQ, the ftrace function floor). The collector's
`fold_clone` in `tool/lua/coverage.lua` strips the spec's suffixes
`\.(isra|constprop|part|cold)\.[0-9]+$`, but this gcc also emits bare
`.cold` partitions with no numeric suffix: 8 in binding files on head
`394ff335` (`LuaUnixDup.cold`, `Parse.cold`,
`db_sql_finalize_function.cold`, …). They are `t` symbols in the
`nm -l` denominator, so they inflate `defined` (545 rather than 537),
and they can never be covered: a `.cold` partition has no patchable
entry, so it never appears in a FUN line (0 in `coverage.txt`). The
committed floor's `defined` column therefore overstates each affected
file by its cold partitions. Re-measure at pull time:
`.cosmocc/current/bin/x86_64-linux-cosmo-nm -l --defined-only
o//tool/lua/lua.dbg | grep -c '\.cold '`.

## Change

`tool/lua/coverage.lua`: fold a bare `.cold` suffix into its parent
function in both the log names and the `nm` denominator (a cold
partition is part of the function it splits from, so its parent's
reach counts). Rebaseline `tool/lua/coverage_floor.lua`
(`COVERAGE_BASELINE=1`) and record the new denominator in the PR.

## Non-goals

- No change to which tests are traced or skipped.
- No `covered` floor lowered: folding removes uncoverable rows from
  `defined` only.
