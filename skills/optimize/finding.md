# Finding optimization opportunities (cosmic layer)

chapter of the `optimize` skill (`SKILL.md` in this directory) — read
that first. this file covers spotting wins in the Teal wrapper layer
(`cosmic/*.tl`); for the C layer see `cosmopolitan.md` in this
directory.

check the hypothesis backlog first (GitHub issues labeled `perf` in
whilp/cosmic) — it holds vetted, evidence-backed starting points, and
the closed-as-completed issues are worked examples of every shape
below. to find new ones, read the harness output and look for these
shapes — and when one crystallizes, write it up as an issue, never as
a note in the tree:

- **implementation mismatches between siblings.** two scenarios doing
  comparable work on the same input should cost comparable time; a
  codec roundtrip running ~8x its sibling means one wrapper is a
  pure-Lua `gsub` loop while the other delegates to a C binding. check
  `o/_types/types_gen/cosmo.d.tl` for an unused binding before writing
  one — preserving the documented error returns while delegating the
  hot path is the archetypal cosmic-layer win.
- **wrappers redoing work the C binding already did** — a `:lower()`
  on output that is already lowercase, a second validation scan the
  first scan already proved, a second `getcwd()` for a value already
  fetched.
- **high `alloc` with high ns/op** — allocation-heavy Lua (string
  concatenation in loops, per-item closures, full record builds where
  3 fields are used).
- **`cpu/wall ≈ 1.0` on I/O scenarios** — a workload you expected to be
  I/O-bound but that burns CPU (e.g. rebuilding strings per chunk).
- **repeated syscalls with cacheable results** — stat(2) per entry
  where dirent d_type already answers the question, makedirs per file
  where files share directories, a fresh sqlite prepare per identical
  SQL string.
- **pairs of scenarios that bracket a layer.** `http_fetch_get` vs
  `http_tcp_roundtrip` isolates the fetch-wrapper overhead from raw
  socket cost; `startup_run_teal` vs `startup_run_lua` isolates the Teal
  loader from runtime boot.
- **profile a single scenario** by bisection: an `--only <name>` run
  is cheap; temporarily splitting a scenario's fn into narrower
  scenarios in a scratch bench file localizes the cost. delete scratch
  scenarios before committing.
- **alloc-per-op sanity math.** for each scenario ask "what does one op
  *have* to allocate?" and compare to the `alloc` column — the gap is
  machinery. a single-row sqlite point query has to allocate roughly
  one row table; kilobytes per op means the code is building fresh
  iterator tables, closures, or column-name lists on every call, and
  reading the wrapper finds which.
- **audit hot wrappers for validation scans.** grep `cosmic` for
  `match("[^`, `gsub(` used only for validation, and pre-checks ahead
  of a delegated C call — a full-string scan that only exists to pick
  an error message can usually move to the failure branch, as long as
  the happy path stays a single C call. (buying the move with a second
  C call on the happy path is the counter-lesson: measure first.)

## when the wrapper is already thin

if you read the wrapper and it's a two-line delegation to a `cosmo.*`
call, or it already calls `unix.*` directly for every operation, there
is no cosmic-layer fix — the cost is inside the C binding, the Lua
runtime, or the kernel. record that finding on the issue, and open (or
move it to) a `perf`-labeled issue in whilp/cosmopolitan, then
continue with `cosmopolitan.md`.
