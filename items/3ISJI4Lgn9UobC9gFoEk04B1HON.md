Four small checker gaps left casts or workarounds behind after the G3
casts sweeps, and all four live in the checker this repo already
patches (3p/tl/tl_patch.tl, mechanism in _make/patch.tl). Evidence
2026-08-26, each probed against the built checker during the sweeps:
(1) table.pack(...).n types integer for uniform arguments but erases
to any when the packed call returns mixed types
(pack(coroutine.resume(t)).n), leaving the one re-reasoned cast in
cosmic/coverage/init.tl's resume wrapper; (2) `x or fallback` fails to
narrow in three sites whose casts say so ("or fallback does not
narrow"); (3) flow narrowing is dropped at every closure boundary even
for locals never reassigned after the guard — the guard-then-typed-
local idiom in coverage/init.tl and _tool/benchmark.tl exists only for
this; (4) metatable<any> is a nominal `is` refuses to dispatch on,
keeping cosmic/fs/types.tl's getmetatable cast. Each is an anchored
patch-group candidate in the same style as the landed narrow-*
entries; (1) and (4) look one-entry small, (3) needs a
reassignment-analysis guard to stay sound, (2) needs the failing
shapes enumerated first. A slice should take them one at a time with a
probe file per gap, extending cosmic/teal_narrowing_test.tl as each
boundary moves.
