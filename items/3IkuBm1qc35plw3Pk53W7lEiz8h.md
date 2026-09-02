## Evidence

Found by the second-round review of cosmic-lua/cosmopolitan#347 (item
3IkcBw7Z, the lunix.c shape-comment gate). In
`tool/lua/test_definitions_help.lua` a block is read only when every
branch line carries the signature's exact indent; a branch line with
one extra space (mutation: `third_party/lua/cosmo/lunix.c:2119`, one
added space) makes the parser drop the whole block, and the gate
passes reporting 157 blocks instead of 158 — the block leaves the gate
silently. The only floor is `#blocks > 50` per source
(`test_definitions_help.lua:163` at head `3d246f7e`), so up to two
thirds of either source could drift out of the gate before it noticed.
Inherited from #345's grammar for `help.txt`, narrowed but not closed
by #347. Re-measure at pull time: add one space to a `├─→` line in
either source and run `make -j$(nproc) o//tool/lua/test`; read whether
the reported block count moves and the gate still passes.

## Change

`tool/lua/test_definitions_help.lua`: two guards, either of which
closes the silent drop —

1. A malformed-block failure: a line starting with the shape glyphs
   (`├─→`, `└─→`, `│`) whose indent does not match the open block (or
   that follows no open block) is a failure by file:line, not a skip.
2. A per-source floor pinned at the current count (`123` for help.txt,
   `158` for lunix.c at #347's head), raised in the same commit that
   adds blocks, so a vanished block fails the gate by count.

Do (1); do (2) as well if it costs one line. Both sources. The counts
the gate prints stay as they are.

## Non-goals

- No lunix.c, help.txt or definitions.lua content change beyond what
  the new guard's first run reports (comment lines only).
