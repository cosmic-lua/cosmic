# Optimizing cosmic performance

this document is the operating manual for performance work on cosmic. it
defines a measurement-driven loop with hard gates, so optimization can be
executed mechanically — including by an agent — without risking functional
or style regressions. read it top to bottom once before changing anything.

it is the front door of a small set of documents, each kept in its own
file so no chapter ever fights the repo's 500-line-per-file cap:

- `lib/perf/OPTIMIZE.md` — this file: the harness, the loop, the rules.
- `lib/perf/optimize/finding.md` — how to find cosmic-layer opportunities.
- `lib/perf/optimize/cosmopolitan.md` — how to optimize the C layer
  (whilp/cosmopolitan) with a local build, no release required.
- `lib/perf/optimize/measurement.md` — measurement discipline and noise.
- `lib/perf/backlog/` — the hypothesis backlog, one file per entry
  (see its README.md).

## the harness in one minute

`lib/perf` benchmarks ~25 end-to-end scenarios (JSON, SQLite, HTTP client,
filesystem, hashing/codecs/compression, binary startup, Teal compilation,
subprocess spawn). every scenario validates its own output with a
`check()` function, so a change that makes a workload faster but wrong
FAILS the benchmark.

```bash
bin/make perf                 # run all scenarios, write o/perf/current.json
bin/make perf-baseline        # snapshot results to o/perf/baseline.json
bin/make perf-compare         # re-run and fail on regression vs baseline
bin/make perf PERF_ONLY=json  # filter scenarios by Lua pattern
```

knobs: `PERF_SAMPLES` (default 5), `PERF_MIN_SECS` (default 0.15),
`PERF_THRESHOLD` (regression bar in percent, default 10), `PERF_BIN`
(which cosmic binary to measure), `COSMO_LUA` (for `perf-bin`; see the
cosmopolitan chapter).

report columns, per scenario:

```
sqlite_point_query    4537 x   12.62 µs/op  ± 0.7%  cpu/wall 1.00  alloc 2.36 KB
```

- `N x` iterations per sample; `µs/op` is the median across samples.
- `±%` spread across samples — treat deltas smaller than this as noise.
- `cpu/wall` — near 1.0 means CPU-bound (optimize algorithms/allocations);
  well below 1.0 means the time is in syscalls, I/O, or child processes.
- `alloc` — Lua-side KB allocated per op; high values mean GC pressure.

## the two layers

every scenario calls `cosmic.*` wrappers (Teal, this repo), which call
the `cosmo.*` C bindings compiled into the cosmos binary (C, built from
whilp/cosmopolitan). the same numbers therefore measure both layers, and
an optimization can land in either:

- **cosmic layer** — pure-Lua work a C binding could do, redundant
  syscalls, dead allocations, missing caches. fixed in `lib/cosmic/*.tl`
  here. see `optimize/finding.md`.
- **cosmopolitan layer** — the C bindings themselves, the Lua runtime,
  the APE loader and zip filesystem (`startup_*` scenarios). fixed in a
  whilp/cosmopolitan checkout and measured against a locally built
  binary via `bin/make perf-bin` — you do NOT need to cut a release to
  measure a C change. see `optimize/cosmopolitan.md`.

after ~20 rounds the cheap cosmic-layer wins are thinning out; check
`grep -l "status: open" lib/perf/backlog/*.md` — the open entries lean
increasingly toward the cosmopolitan layer.

## the optimization loop

work ONE scenario (or one closely related group) at a time.

1. **baseline** on a quiet machine, from a clean tree:
   `git status` must be clean, then `bin/make perf-baseline`.
   (for cosmopolitan-layer work, baseline the unmodified LOCAL build
   instead — `optimize/cosmopolitan.md` has the exact commands.)
2. **pick a target** (see `optimize/finding.md` and the backlog). state
   a hypothesis: *"X is slow because Y; changing Z should cut ns/op by
   W%."*
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
   the commit message (copy the `perf-compare` lines), and update the
   backlog entry file in the same commit.

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

## the hypothesis backlog

`lib/perf/backlog/` holds the log — one file per concrete,
evidence-backed starting point, `open`/`done`/`rejected`. work it like
this: pick ONE open entry, run the loop above, then update the entry's
file in the same commit. rejected entries stay forever; they save the
next agent from re-testing a dead end. `lib/perf/backlog/README.md`
documents the format.

if a workload you want to optimize has no scenario, add one FIRST (in a
`lib/perf/bench/*_bench.tl` module, with a real `check()`), baseline it,
then optimize.
