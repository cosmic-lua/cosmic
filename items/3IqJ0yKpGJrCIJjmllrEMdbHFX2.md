## Evidence

Found during review of board item `3IptmlaFwaGNOmguaiefU6lyGKY` («fU6l_yGKY»,
PR cosmic-lua/cosmopolitan#379, the `finger.*` demo fix) — same class of bug,
a different symbol, confirmed live by the reviewer:

`tool/net/demo/maxmind.lua` does `local maxmind = require "maxmind"` and
calls `maxmind.open(...)`; `tool/net/help.txt`'s MAXMIND MODULE section
documents the same surface. No `luaopen_maxmind` binding exists anywhere in
the tree: `third_party/maxmind/maxminddb.c` is the raw C library, unbound
to Lua; `tool/viz/maxmind.c` is an unrelated standalone CLI tool in
`tool/viz/`, not a Lua binding. `tool/net/BUILD.mk` still embeds
`maxmind.lua` into the demo zip regardless, so any request that reaches it
should 500 with `attempt to index a nil value (global 'maxmind')` or
`attempt to call a nil value (field 'open')`, the same shape as the
`finger.*` and `VisualizeControlCodes` bugs already fixed in
cosmic-lua/cosmopolitan#378 and #379.

## Change

Same shape as `Ba69_burI` (#378) and `3IptmlaFwaGNOmguaiefU6lyGKY` (#379):
confirm live (build `o//tool/net/redbean-demo`, hit whatever route serves
`tool/net/demo/maxmind.lua`, confirm the exact 500) and determine whether
`maxmind.*` is a binding that was removed and never cleaned up downstream,
or one that was never wired up despite being documented — check binding
history the way `tool/lua/test_cosmo.lua:89` documents `VisualizeControlCodes`'s
removal. Fix `tool/net/demo/maxmind.lua`, `tool/net/help.txt`'s MAXMIND
MODULE section, and `tool/net/BUILD.mk`'s embed list to be consistent with
whichever direction the binding's actual state supports — restore the
binding, or remove the demo/`help.txt`/BUILD.mk references, matching the
prior two items' resolution pattern.

## Non-goals

Not `finger.*` or `VisualizeControlCodes` themselves — already resolved.
Not a broader audit of every demo script for drifted bindings beyond
`maxmind.*`.
