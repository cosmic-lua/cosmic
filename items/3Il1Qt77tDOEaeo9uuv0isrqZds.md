## Problem

The fork's Lua bindings are the part of cosmopolitan cosmic depends on
and modifies most (`tool/net/l*.c`, `tool/lua/lcosmo.c`,
`third_party/lua/cosmo/lunix.c`: ~10,000 lines at origin/master
2026-09-02), and nothing measures how much of that C the test target
exercises. What exists gates the SURFACE, not the code:
`tool/lua/test_definitions_coverage.lua` ratchets that every registered
binding is annotated; `test_definitions_conformance.lua` type-checks a
curated set of pure bindings at runtime; #345/#347 gate the shape
comments. Measured 2026-09-02: of 417 annotated functions and methods
in `tool/net/definitions.lua`, 206 are referenced by name in any
`tool/lua/test_*.lua`; the rest (120 unix methods and predicates, 79
lsqlite3, 12 zip) can regress silently. cosmic's own `.cosmic-coverage`
ratchets Teal line coverage per wrapper file and has no C analogue.
`tool/net/lcov.c` is a Lua line-hit collector, not C coverage; no
`-fprofile-arcs`/gcov appears anywhere in `build/` or `tool/lua/BUILD.mk`.

## Outcome

A per-file C line-coverage floor for the binding sources, ratcheted
the way `.cosmic-coverage` is: a `MODE` that instruments those files,
a committed floor file, and a gate in the test target that fails when
a file's covered-line count drops below its floor and rewrites the
floor only on request. The first slice decides feasibility: whether
cosmocc's GCC can instrument for gcov and whether the resulting APE
binary writes `.gcda` under cosmopolitan's runtime at all.

## Non-goals

- No change to which bindings the tests exercise (raising coverage is
  ordinary follow-on work the ratchet then protects).
- No instrumentation outside `tool/net`, `tool/lua`, and
  `third_party/lua/cosmo` — the fork stays mergeable with upstream.
