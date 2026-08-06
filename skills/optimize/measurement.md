# Measurement discipline

chapter of the `optimize` skill (`SKILL.md` in this directory) — read
that first.

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
- **`perf-compare` triages this for you — trust its verdict, don't
  hand-roll A/B runs.** after its re-measure retry, if a regression
  still stands it runs one more pass of the SAME binary and compares it
  against itself (an A/A self-check); any flagged scenario that also
  swings past the bar against itself is reclassified `noise` and does
  NOT fail the gate. so `perf-compare` exits 0 when every survivor is
  machine noise and nonzero only on a regression the binary reproduces
  against itself. read the final report: `regression` = real (a stable
  scenario that moved), `noise` = discounted (a scenario too variable to
  judge here). this is the entry 21 story made automatic:
  `json_decode_*` reproduced at ~-30% while `hash`/`startup_*` tripped
  the bar only on variance an A/A control also shows.
- the reclassification is deliberately conservative: it only ever
  downgrades a `regression`, only when the current binary cannot
  reproduce that scenario's timing against itself, AND only when the
  regression's own size is comparable to that self-check swing (within
  2x — `TRIAGE_K` in `_perf/compare.tl`). instability alone is not a
  blank check: a scenario whose A/A wobbles 5% does not excuse a +300%
  regression, so a real regression in a stable scenario (json, sqlite,
  codec) — or a huge one in an unstable scenario — has nowhere to hide
  and stays `regression`.
- `gate.lua selfcheck` runs the same A/A control on demand, for
  interactive use or to profile the machine's noise floor before you
  start. `--only <name>` narrows it to one
  scenario. for a still-suspect scenario, re-measuring it in isolation
  on both builds back to back (`run.lua --only <name>` on A,
  then on B) also removes the thermal/cache wake left by the ~20
  scenarios that precede it in a full suite.
- prefer the default `--samples`/`--min-secs` for accept/reject
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
- **know which binary you measured.** `$BIN` is a path, and two things
  now move what sits at that path without you asking. `bin/cosmic`
  prefers `o/bin/cosmic` when one exists and reaches for the pin only
  on a cold start; and a gate verb CONVERGES, building the tree and
  re-execing into the result (`_make/converge.tl`), so a stray
  `--make ci` between baseline and current silently replaces the thing
  under test. Both are right for correctness and both are measurement
  hazards, because a benchmark's subject has to hold still.

  So: baseline and compare against paths you built deliberately, in one
  sitting, and re-run `--make build` before each measurement rather
  than assuming the binary is what it was — and read that build's
  verdict, because a build that fails before assembly leaves the
  previous binary in place. If a result is surprising, hash the binary
  on both sides (`sha256sum o/bin/cosmic`) before you believe it. Not
  `--version`: its cosmos half is stamped from the pin file at embed
  time, so it reports the pin even when a local runtime was stood in
  by hand (`cosmopolitan.md` step 2). Every results file records
  `meta.bin_sha`, and the compare gate refuses a compare whose two
  sides hashed the same binary. This is the
  same class as the coverage floors' sensitivity to which compiler
  built the artifact (`cosmic/coverage/SENSITIVITY.md`): a metric
  measured through an artifact inherits that artifact's identity as a
  hidden input.
