# Measurement discipline

chapter of `lib/perf/OPTIMIZE.md` — read that first.

- machine noise is real: nothing else heavy runs during measurement;
  baseline and comparison run on the same machine, same power state.
- the compare bar auto-widens to each scenario's observed spread, and
  `perf-compare` re-measures once before failing — but if results still
  look inconsistent, re-run `perf-compare`; a genuine change reproduces
  in the same direction every time. backlog entry 11 is a worked
  example: an unrelated `startup_*` regression flagged on the first
  pass vanished on a clean re-run while the real win reproduced.
- prefer default `PERF_SAMPLES`/`PERF_MIN_SECS` for accept/reject
  decisions; use lower values only for quick scouting.
- scenarios must be stationary: an op must not get slower the more often
  it runs (growing tables, leaking fds, write-churn on overlay
  filesystems). the insert scenario deletes inside its transaction and
  fs scenarios stick to stable operations for exactly this reason.
- compare like against like. the pinned release binary and a local
  cosmopolitan build differ by toolchain, commit drift, and build
  environment — never judge a C change by comparing your modified
  local build against the pinned binary. baseline an UNMODIFIED local
  build and A/B two local builds that differ only by your change
  (`cosmopolitan.md` walks through it).
- scenarios whose per-op cost is large (tens of ms, e.g. `embed_*`)
  fit few iterations per sample and show wide spread; expect to need
  several consistent re-measures rather than one clean cross of the
  noise bar (entries 16, 17), and consider whether the workload can be
  shaped so the effect under test isn't swamped by a fixed floor.
- a win must be explainable. if you can't say WHY the number moved
  (fewer syscalls, fewer allocations, one scan instead of two), treat
  it as noise until you can.
