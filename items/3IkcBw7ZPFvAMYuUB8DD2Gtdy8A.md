## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#345 (the help.txt
shape gate). `third_party/lua/cosmo/lunix.c` carries a hand-written
`├─→`/`└─→` shape comment above each `LuaUnix*` function — e.g.
`// unix.fsync(fd:int)` at `lunix.c:1739` and `// unix.tiocgwinsz(fd:int)`
at `lunix.c:2970` (at `b6b757c9`) — and nothing gates those against
`tool/net/definitions.lua`. It is the same drift class #345 closed for
`help.txt`, in a second hand-maintained copy: #336's round-1 review
found `LuaUnixGetpgrp`'s comment still declaring a failure tuple after
the annotation was retyped, and the fix had to be requested by hand.
Re-measure at pull time: `grep -c '└─→' third_party/lua/cosmo/lunix.c`
for how many blocks the file carries, and diff the fallibility each
block declares against `definitions.lua` the way
`tool/lua/test_definitions_help.lua` does for help.txt.

## Change

`tool/lua/test_definitions_help.lua` (from #345) already parses
`├─→`/`└─→` blocks and compares branch-count fallibility against
`definitions.lua`. Extend it — or add a sibling
`tool/lua/test_definitions_lunix.lua` if the file's shape makes a second
source awkward — to read `third_party/lua/cosmo/lunix.c`'s
`// unix.<name>(...)` comment blocks with the same parser and apply the
same count-level comparison, failing by `lunix.c` line. Whatever the
first run reports becomes this PR's fix list (comment lines only, no C
code), unless it exceeds a dozen entries — then land the gate with an
explicit allowlist and file the rest as one follow-up. Enrol any new
test in `tool/lua/BUILD.mk` as a complete block with its own `@touch $@`.

## Non-goals

- No C code change; comment lines only.
- No `definitions.lua` change.
