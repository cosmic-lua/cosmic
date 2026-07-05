# Finding optimization opportunities (cosmic layer)

chapter of `lib/perf/OPTIMIZE.md` — read that first. this file covers
spotting wins in the Teal wrapper layer (`lib/cosmic/*.tl`); for the C
layer see `cosmopolitan.md` in this directory.

check the hypothesis backlog first (`lib/perf/backlog/`) — it holds
vetted, evidence-backed starting points. to find new ones, read
`bin/make perf` output and look for the shapes below. the backlog's
`done` entries are worked examples of each.

- **implementation mismatches between siblings.** example found during
  harness bring-up: `codec_hex_roundtrip_64k` ran ~17.6ms while
  `codec_base64_roundtrip_64k` ran ~2.1ms on the same input. cause:
  `codec.decode_hex` was a pure-Lua `gsub` with a per-byte-pair callback
  plus two validation scans, while a `cosmo.DecodeHex` C binding existed
  (`lib/types/cosmo.d.tl`) unused. preserving the documented error
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
- **profile a single scenario** by bisection: `bin/make perf
  PERF_ONLY=<name>` is cheap; temporarily splitting a scenario's fn into
  narrower scenarios in a scratch bench file localizes the cost. delete
  scratch scenarios before committing.

## when the wrapper is already thin

if you read the wrapper and it's a two-line delegation to a `cosmo.*`
call (like `json.decode`, entry 7), or it already calls `unix.*`
directly for every operation (like `child.spawn`, entry 12), there is
no cosmic-layer fix — the cost is inside the C binding, the Lua
runtime, or the kernel. record that finding in the backlog entry,
set `layer: cosmopolitan`, and continue with `cosmopolitan.md`.
