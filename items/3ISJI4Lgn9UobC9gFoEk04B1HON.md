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

## Result (container verification, 2026-08-27)

All four gaps closed in the checker, each by a landed child, each
pinned by a test on main c78504bd:

1. pack-n — 3ISKgfS6 (#1409 entry, #1423 cast retire);
   `test_mixed_pack_keeps_n_integer`. The coverage resume wrapper
   carries no cast.
2. or-fallback — the value-position rule landed with the narrow set;
   `test_or_fallback_drops_nil` (now in teal_nilflow_test.tl). No
   "or fallback does not narrow" cast remains in the tree (grep
   clean).
3. closure carry — 3ISSGDIN (#1442, nine closure-* entries);
   teal_closure_test.tl's four tests. 3ISSGm9B closed with its
   diagnosis corrected on the record.
4. metatable is-dispatch — 3ISSFrCO (#1439, three entries);
   `test_metatable_is_table_narrows` / `..._scalar_is_refused`.

Residue: the SOURCE-side workaround retires (fs/types.tl cast,
coverage/benchmark closure idiom) wait on a pin carrying the rules —
filed as 3IU5Vhvy under G3, with the pull-time gate stated.
