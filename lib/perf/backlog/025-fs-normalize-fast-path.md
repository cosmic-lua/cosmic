# 25. fs_path.normalize splits and rebuilds every path, even already-normal ones

- status: open
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
