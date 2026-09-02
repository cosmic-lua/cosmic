## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#347 (the lunix.c
shape-comment gate, item 3IkcBw7Z). At `f96adf44`,
`third_party/lua/cosmo/lunix.c` carries 220 `└─→` shape blocks; #347's
gate (and #345's for `help.txt`) reads only the 150 top-level
`// unix.<name>(` function blocks. The other 70 are hand-maintained
too and nothing compares them to `tool/net/definitions.lua`: 66
`// unix.<Type>:<method>(` blocks (`unix.Stat:size()`, `unix.Rusage:…`,
`unix.Sigset:…`, `unix.Dir:…`) plus 2 `sandbox.*` and 2 whose prefix is
mistyped — `lunix.c:3589` reads `// unid.Rusage:idrss()` and `:3595`
reads `// unis.Rusage:isrss()` where the surrounding blocks read
`// unix.Rusage:…`. Those two typos are exactly what an ungated copy
drifts into, and a gate keyed on the `unix.` prefix would skip them
silently rather than flag them. `help.txt` carries the same
`unix.<Type>:<method>()` blocks. Re-measure at pull time:
`grep -cE '^// unix\.[A-Z][A-Za-z]*:' third_party/lua/cosmo/lunix.c`
and `grep -nE '^// uni[^x]' third_party/lua/cosmo/lunix.c`.

## Change

`tool/lua/test_definitions_help.lua`: extend the signature pattern the
parser accepts to `unix.<Type>:<method>(` in both sources (help.txt and
lunix.c), looking the block up as `function unix.<Type>:<method>(` in
`definitions.lua`, with the same count-level fallibility comparison
and the same by-line failure. Every block whose first line starts with
`// uni` but is not `// unix.` is a failure by line (so the two typos
are caught, not skipped). Whatever the first run reports becomes this
PR's fix list (comment lines only, the two typos included), unless it
exceeds a dozen entries — then land the gate with an explicit
allowlist and file the rest as one follow-up. `tool/lua/BUILD.mk`'s
rule keeps its `@touch $@`.

## Non-goals

- No C code change; comment lines only.
- No `definitions.lua` change.
- The 2 `sandbox.*` blocks stay outside the gate (their annotations
  live under a different table); say so in a comment where the
  pattern is defined.
