# Optimizing cosmic performance

this document is the operating manual for performance work on cosmic. it
defines a measurement-driven loop with hard gates, so optimization can be
executed mechanically — including by an agent — without risking functional
or style regressions. read it top to bottom once before changing anything.

## the harness in one minute

`lib/perf` benchmarks ~20 end-to-end scenarios (JSON, SQLite, HTTP client,
filesystem, hashing/codecs/compression, binary startup, Teal compilation).
every scenario validates its own output with a `check()` function, so a
change that makes a workload faster but wrong FAILS the benchmark.

```bash
bin/make perf                 # run all scenarios, write o/perf/current.json
bin/make perf-baseline        # snapshot results to o/perf/baseline.json
bin/make perf-compare         # re-run and fail on regression vs baseline
bin/make perf PERF_ONLY=json  # filter scenarios by Lua pattern
```

knobs: `PERF_SAMPLES` (default 5), `PERF_MIN_SECS` (default 0.15),
`PERF_THRESHOLD` (regression bar in percent, default 10), `PERF_BIN`
(which cosmic binary to measure).

report columns, per scenario:

```
sqlite_point_query    4537 x   12.62 µs/op  ± 0.7%  cpu/wall 1.00  alloc 2.36 KB
```

- `N x` iterations per sample; `µs/op` is the median across samples.
- `±%` spread across samples — treat deltas smaller than this as noise.
- `cpu/wall` — near 1.0 means CPU-bound (optimize algorithms/allocations);
  well below 1.0 means the time is in syscalls, I/O, or child processes.
- `alloc` — Lua-side KB allocated per op; high values mean GC pressure.

## the optimization loop

work ONE scenario (or one closely related group) at a time.

1. **baseline** on a quiet machine, from a clean tree:
   `git status` must be clean, then `bin/make perf-baseline`.
2. **pick a target** (see "finding opportunities" below). state a
   hypothesis: *"X is slow because Y; changing Z should cut ns/op by W%."*
3. **change the code.** smallest diff that tests the hypothesis. follow
   every repo convention (AGENTS.md): Teal, 2-space indent, ≤500-line
   files, `value, string` error returns, wrappers keep their documented
   behavior and error messages.
4. **gate 1 — correctness and style:** `bin/make ci` must pass
   (format + type check + tests + examples). the perf smoke test
   (`lib/perf/perf_test.tl`) runs every scenario end to end in CI, so a
   broken scenario check fails here too.
5. **gate 2 — performance:** `bin/make perf-compare`. it re-measures,
   compares against your baseline with a noise-aware bar
   (max of `PERF_THRESHOLD`, baseline spread, current spread), retries
   once on failure to filter machine noise, and exits nonzero if any
   scenario regressed, errored, or disappeared.
6. **decide.**
   - target scenario improved beyond its noise bar and nothing else
     regressed → keep it.
   - no measurable improvement, or anything else regressed → `git
     checkout` the change and record the failed hypothesis.
7. **commit**, quoting before/after numbers for the affected scenarios in
   the commit message (copy the `perf-compare` lines).

## hard rules (guardrails)

- NEVER delete, rename, or weaken a scenario or its `check()` to make a
  comparison pass. `perf-compare` treats missing scenarios as failures and
  the smoke test rejects scenarios without checks — do not work around
  either. renames belong in a separate, no-code-change commit that also
  re-baselines.
- NEVER commit `o/perf/*.json`. baselines are machine-specific and live
  only in your working `o/` directory.
- a wrapper's observable behavior (return values, error strings, edge
  cases like empty input) is part of its contract. optimizations that
  change behavior are rejected by `bin/make ci` / scenario checks — fix
  the approach, not the test.
- one hypothesis per commit. if `bin/make ci` fails, you are done with
  that hypothesis until it passes; never trade correctness for speed.
- benchmarks live under `lib/perf/bench/` and use `cosmic.*` modules only
  (never raw `cosmo.*`) — they measure what users experience.

## finding opportunities

read `bin/make perf` output and look for:

- **implementation mismatches between siblings.** example found during
  harness bring-up: `codec_hex_roundtrip_64k` ran ~17.6ms while
  `codec_base64_roundtrip_64k` ran ~2.1ms on the same input. cause:
  `codec.decode_hex` is a pure-Lua `gsub` with a per-byte-pair callback
  plus two validation scans, while a `cosmo.DecodeHex` C binding exists
  (`lib/types/cosmo.d.tl`). preserving the documented error returns while
  delegating the hot path is the archetypal cosmic-layer win.
- **high `alloc` with high ns/op** — allocation-heavy Lua (string
  concatenation in loops, per-item closures). e.g. `json_decode_large`
  allocates ~375KB/op; how much is unavoidable C-side table building vs
  wrapper overhead is a question worth answering.
- **`cpu/wall ≈ 1.0` on I/O scenarios** — a workload you expected to be
  I/O-bound but that burns CPU (e.g. rebuilding strings per chunk).
- **pairs of scenarios that bracket a layer.** `http_fetch_get` vs
  `http_tcp_roundtrip` isolates the fetch-wrapper overhead from raw
  socket cost; `startup_run_teal` vs `startup_run_lua` isolates the Teal
  loader (~13ms today) from runtime boot (~14.5ms).
- **profile a single scenario** by bisection: `bin/make perf
  PERF_ONLY=<name>` is cheap; temporarily splitting a scenario's fn into
  narrower scenarios in a scratch bench file localizes the cost. delete
  scratch scenarios before committing.

if a workload you want to optimize has no scenario, add one FIRST (in a
`lib/perf/bench/*_bench.tl` module, with a real `check()`), baseline it,
then optimize.

## optimizing the cosmo/cosmopolitan layer end to end

scenarios call `cosmic.*` wrappers, which call the `cosmo.*` C bindings
from the pinned cosmos binary, so C-layer changes show up in the same
numbers. `startup_*` scenarios additionally cover the APE loader, zip
filesystem, and Lua boot — the parts that only change when the
cosmopolitan pin changes.

to evaluate a cosmopolitan-side change (in whilp/cosmopolitan):

1. baseline with the current pin: `bin/make perf-baseline`.
2. build or fetch a cosmos release with the change and produce a cosmic
   binary from it: bump `3p/cosmos/version.lua` (url + sha256), run
   `bin/make regen-types && bin/make build` and fix any wrapper breakage
   (see AGENTS.md "Type Generation").
3. `bin/make perf-compare` now measures old pin vs new pin with identical
   scenarios. `PERF_BIN=/path/to/other/cosmic bin/make perf` measures any
   prebuilt binary without touching the pin; results record the binary in
   `meta.bin`.

## measurement discipline

- machine noise is real: nothing else heavy runs during measurement;
  baseline and comparison run on the same machine, same power state.
- the compare bar auto-widens to each scenario's observed spread, and
  `perf-compare` re-measures once before failing — but if results still
  look inconsistent, re-run `perf-compare`; a genuine change reproduces
  in the same direction every time.
- prefer default `PERF_SAMPLES`/`PERF_MIN_SECS` for accept/reject
  decisions; use lower values only for quick scouting.
- scenarios must be stationary: an op must not get slower the more often
  it runs (growing tables, leaking fds, write-churn on overlay
  filesystems). the insert scenario deletes inside its transaction and
  fs scenarios stick to stable operations for exactly this reason.
