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
- **the `±%` in the report is WITHIN-run spread; it understates
  cross-run variance.** a scenario can read ±2% across the 5 samples of
  one invocation yet swing 10-15% between two separate invocations —
  frequency scaling, a noisy neighbor on a shared runner, or code-layout
  shift from relinking (C-layer builds) all move fixed-overhead
  microbenchmarks (`hash_sha256_small`, `startup_run_*`, `net_ip_*`)
  without touching their code. so the compare bar, derived from
  within-run spread, will flag these as "regressions" on pure noise.
- **when `perf-compare` flags a scenario your change does not touch,
  do not spend a round hand-rolling A/B runs — run the built-in A/A
  control:** `bin/make perf-selfcheck` measures the SAME binary twice
  and compares it against itself, so anything it flags is this machine's
  noise floor, not your edit. `PERF_ONLY=<name> bin/make perf-selfcheck`
  narrows it to just the flagged scenario for a fast answer. if
  `perf-selfcheck` flags the same scenario at a similar magnitude, the
  `perf-compare` "regression" there is noise; discount it and judge the
  change by (a) your TARGET scenario moving well beyond its own noise
  floor and (b) that movement reproducing every run. this is the entry
  21 story: `json_decode_*` reproduced at ~-30% on every run while the
  flagged `hash`/`startup_*` scenarios tripped the bar in an A/A control
  of an unmodified binary against itself.
- for a scenario perf-compare flagged, an alternative to `perf-selfcheck`
  is to re-measure just it in isolation on both builds back to back:
  `PERF_ONLY=<name> bin/make perf` on binary A, then on binary B. an
  isolated run also removes the thermal/cache wake left by the 20-odd
  scenarios that precede it in a full suite, which is itself a source of
  drift for the cheap scenarios near the end.
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
