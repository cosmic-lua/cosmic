# 25. fs_path.normalize splits and rebuilds every path, even already-normal ones

- status: done (2026-07-05)
- layer: cosmic
- scenario: fs_relpath_relative

- evidence: `fs_relpath_relative` runs 5.78µs/op with 2.62KB/op alloc
  — high for pure string math on short paths. `normalize()`
  (lib/cosmic/fs_path.tl:73-103) unconditionally splits the path into
  a parts array via `gmatch("[^/]+")` + `table.insert`, then
  `table.concat`s it back — allocating the table, every component
  substring, and the result string on every call. `relpath` with a
  relative input calls it at least once (entry 15 already removed the
  duplicate getcwd; the remaining cost is this). Most real inputs are
  already normalized: no `//`, no `.` or `..` components, no trailing
  slash.
- hypothesis: add a fast path that detects already-normal input with
  one or two cheap scans (e.g. no `"//"` plain-find, no `"/./"` /
  `"/../"` / leading-or-trailing dot component, no trailing `/`) and
  returns the input string unchanged, falling through to the split
  loop otherwise. Also applicable micro-fix in the slow path: replace
  `table.insert(parts, ...)` with an indexed counter (entry 6's
  shape). Expected: large cut of the 2.62KB/op alloc and a
  double-digit percent of ns/op for normal inputs.
- watch out: the fast-path predicate must be *exactly* "output would
  equal input" — e.g. `""` -> `"."`, `"/"` stays `"/"`, a lone `"."`
  -> `"."`, `"a/"` -> `"a"` — enumerate fs_path_test.tl's normalize
  cases and add ones for every predicate edge (a path ending in
  `"/.."`, a component named `"..."` which is a legal filename, etc.)
  before trusting it. entry 19's lesson applies: keep the detection
  to one or two C-implemented full-string calls, not a per-component
  Lua loop, or the fast path eats its own win.
- risk: medium-low — pure function with a thorough existing test
  table; the danger is a subtle predicate miss, which tests must pin.
- result: done. `normalize()` gained a fast path that returns the input
  unchanged when a handful of C-implemented full-string checks prove it
  is already normal: no trailing `/`, no `//`, and no exact `.` / `..`
  component (each tested as whole-string, leading `"./"`/`"../"`,
  trailing `"/."`/`"/.."`, or interior `"/./"`/`"/../"`). The predicate
  is a conservative subset of "output == input" — inputs it does not
  match (e.g. a normal relative path with leading `..`) still fall
  through to the authoritative loop, so it can never return a wrong
  result, only miss a speedup. The slow path also swapped
  `table.insert`/`table.remove` for an indexed counter (entry 6 shape).
  Predicate edges pinned in a new `fs_path_normalize_test.tl`
  (fs_path_test.tl was 498/500 lines, no room): dotty-but-legal names
  (`"..."`, `"a/.../b"`, `"..a/b.."`) pass unchanged, near-miss
  non-normal inputs (`"a/b/.."`, `"foo/."`, `"a//b"`, trailing slash)
  still collapse. `perf-compare`: `fs_relpath_relative` 5.31 µs/op ->
  4.08 µs/op (-23.1%), alloc 2.62 KB/op -> 1.77 KB/op, no regressions
  in the other 31 scenarios. `bin/make ci` green.
