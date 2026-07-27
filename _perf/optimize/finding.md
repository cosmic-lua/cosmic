# Finding optimization opportunities (cosmic layer)

chapter of `_perf/OPTIMIZE.md` — read that first. this file covers
spotting wins in the Teal wrapper layer (`cosmic/*.tl`); for the C
layer see `cosmopolitan.md` in this directory.

check the hypothesis backlog first (GitHub issues labeled `perf` in
whilp/cosmic) — it holds vetted, evidence-backed starting points. to
find new ones, read the harness output and look for the shapes
below. the closed-as-completed issues are worked examples of each.

- **implementation mismatches between siblings.** example found during
  harness bring-up: `codec_hex_roundtrip_64k` ran ~17.6ms while
  `codec_base64_roundtrip_64k` ran ~2.1ms on the same input. cause:
  `codec.decode_hex` was a pure-Lua `gsub` with a per-byte-pair callback
  plus two validation scans, while a `cosmo.DecodeHex` C binding existed
  (`o/_types/types_gen/cosmo.d.tl`) unused. preserving the documented error
  returns while delegating the hot path is the archetypal cosmic-layer
  win (backlog entries 1, 10, 11, 13).
- **wrappers redoing work the C binding already did** — dead
  `:lower()` on already-lowercase output (entry 9), a second validation
  scan the first scan already proved (entry 18), a second `getcwd()`
  for a value already fetched (entry 15).
- **high `alloc` with high ns/op** — allocation-heavy Lua (string
  concatenation in loops, per-item closures, full record builds where
  3 fields are used — entry 11).
- **`cpu/wall ≈ 1.0` on I/O scenarios** — a workload you expected to be
  I/O-bound but that burns CPU (e.g. rebuilding strings per chunk).
- **repeated syscalls with cacheable results** — stat(2) per entry
  where dirent d_type already answers the question (entries 5, 16),
  makedirs per file where files share directories (entry 17), fresh
  sqlite prepare per identical SQL string (entries 2, 8).
- **pairs of scenarios that bracket a layer.** `http_fetch_get` vs
  `http_tcp_roundtrip` isolates the fetch-wrapper overhead from raw
  socket cost; `startup_run_teal` vs `startup_run_lua` isolates the Teal
  loader from runtime boot.
- **profile a single scenario** by bisection: `run.lua
  PERF_ONLY=<name>` is cheap; temporarily splitting a scenario's fn into
  narrower scenarios in a scratch bench file localizes the cost. delete
  scratch scenarios before committing.
- **alloc-per-op sanity math.** for each scenario ask "what does one op
  *have* to allocate?" and compare to the `alloc` column — the gap is
  machinery. a single-row sqlite point query has to allocate roughly
  one row table, yet measured 2.41KB/op; reading the code found a
  fresh iterator table, metatable, two closures, and a col_names
  rebuild per call (entry 23). a relpath on short strings measured
  2.62KB/op; that was normalize's split-into-parts table (entry 25).
- **audit hot wrappers for validation scans.** grep `cosmic` for
  `match("[^`, `gsub(` used only for validation, and pre-checks ahead
  of a delegated C call — a full-string scan that only exists to pick
  an error message can usually move to the failure branch (entries 18,
  22), as long as the happy path stays a single C call (entry 19's
  counter-lesson).

## when the wrapper is already thin

if you read the wrapper and it's a two-line delegation to a `cosmo.*`
call (like `json.decode`, entry 7), or it already calls `unix.*`
directly for every operation (like `child.spawn`, entry 12), there is
no cosmic-layer fix — the cost is inside the C binding, the Lua
runtime, or the kernel. record that finding on the backlog issue, and
open (or move it to) a `perf`-labeled issue in whilp/cosmopolitan, then
continue with `cosmopolitan.md`.
