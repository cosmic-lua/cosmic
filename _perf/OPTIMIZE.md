# Optimizing cosmic performance

this document is the operating manual for performance work on cosmic. it
defines a measurement-driven loop with hard gates, so optimization can be
executed mechanically — including by an agent — without risking functional
or style regressions. read it top to bottom once before changing anything.

it is the front door of a small set of documents, each kept in its own
file so no chapter ever fights the repo's 500-line-per-file cap:

- `_perf/OPTIMIZE.md` — this file: the harness, the loop, the rules.
- `_perf/optimize/finding.md` — how to find cosmic-layer opportunities.
- `_perf/optimize/cosmopolitan.md` — how to optimize the C layer
  (whilp/cosmopolitan) with a local build, no release required.
- `_perf/optimize/measurement.md` — measurement discipline and noise.
- the hypothesis backlog — GitHub issues labeled `perf` (whilp/cosmic
  for cosmic-layer work, whilp/cosmopolitan for the C layer). see
  "the hypothesis backlog" below.

## the harness in one minute

`_perf` benchmarks ~36 end-to-end scenarios across 12 bench modules
(JSON, SQLite, HTTP client, filesystem, hashing/codecs/compression,
binary startup, Teal compilation, subprocess spawn). every scenario
validates its own output with a `check()` function, so a change that
makes a workload faster but wrong FAILS the benchmark.

The harness is scripts, driven through `--make run` by whichever binary
you are measuring. `$BIN` is the cosmic under test (`o/bin/cosmic`, or a
build standing on a locally built cosmopolitan lua — see
`optimize/cosmopolitan.md`).

**Go through `--make run`, and name `$BIN` explicitly.** Two different
identity traps, and both return a number either way:

- **The harness's own identity.** A bare `$BIN _perf/run.tl …` — or
  `$BIN o/_perf/run.lua …`, which reads like the fix and is not — runs
  the tree's entry file and then loads `_perf.harness` and every
  `_perf/bench/*` from the BINARY's embedded copies. Edit a scenario,
  re-run, and nothing changes. `--make run` builds first and resolves
  both against the tree (docs/design/make/resolution.md).
- **The subject's identity.** The trust root prefers `o/bin/cosmic` when
  one exists and falls back to the pin when it does not, so measuring
  through `bin/cosmic` measures whatever `o/` happens to hold.

Both are the measurement-identity trap in `optimize/measurement.md`,
reachable without touching a single knob.

```bash
BENCH=$(ls _perf/bench/*_bench.tl | sed 's|/|.|g;s|\.tl$||')

# run all scenarios into a results file
$BIN --make run _perf/run.tl --out o/perf/current.json $BENCH
# …the same, filtered to one scenario group
$BIN --make run _perf/run.tl --only json --out o/perf/current.json $BENCH

# compare two runs with the noise-aware bar (retries + A/A auto-triage)
$BIN --make run _perf/gate.tl compare o/perf/baseline.json o/perf/current.json \
  o/perf/selfb.json $BENCH

# A/A control: the same binary against itself is the noise floor
$BIN --make run _perf/gate.tl selfcheck o/perf/a.json o/perf/b.json $BENCH
```

A baseline is just a results file you keep: run the unmodified build
into `o/perf/baseline.json` before changing anything.

`gate.tl compare` already handles the false alarm for you: when a
regression survives its retry, it runs one more pass of the same binary
and auto-triages against that A/A self-check — a fixed-overhead
microbench (`hash_sha256_small`, `startup_run_*`, `net_ip_*`) that swung
on frequency scaling, a noisy neighbor, or code-layout shift is reported
as `noise` and does not fail the gate, while a regression the binary
reproduces against itself still fails. (`_perf/run.tl --compare` is the
plain, non-retrying diff the gate builds on — it just diffs two files.)
`gate.tl selfcheck` runs that same A/A control standalone, for
interactive use or to profile the machine's noise floor before you
start. `_perf/optimize/measurement.md` has the full playbook.

knobs: `--samples` (default 5), `--min-secs` (default 0.15),
`--threshold` (regression bar in percent, default 10). `PERF_BIN` is not
a knob on the runner — it is an env var the process-spawning scenarios
(`startup_*`, `embed_*`) read to pick which binary they exec; `run.tl`
itself only records it (or falls back to `arg[-1]`) as a metadata label
in the report. Measuring a local Cosmopolitan build takes no knob — you
stand it in at `o/3p/cosmos/lua` and rebuild; see the cosmopolitan
chapter.

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
  syscalls, dead allocations, missing caches. fixed in `cosmic/*.tl`
  here. see `optimize/finding.md`.
- **cosmopolitan layer** — the C bindings themselves, the Lua runtime,
  the APE loader and zip filesystem (`startup_*` scenarios). fixed in a
  whilp/cosmopolitan checkout and measured against a locally built
  binary by hand — you do NOT need to cut a release to
  measure a C change. see `optimize/cosmopolitan.md`.

after ~20 rounds the cheap cosmic-layer wins are thinning out; check the
open `perf`-labeled issues (`gh issue list --label perf --state open`, in
both whilp/cosmic and whilp/cosmopolitan) — the open ones lean
increasingly toward the cosmopolitan layer.

## the optimization loop

work ONE scenario (or one closely related group) at a time.

1. **baseline** on a quiet machine, from a clean tree: `git status` must
   be clean, then run the harness into `o/perf/baseline.json`.
   (for cosmopolitan-layer work, baseline the unmodified LOCAL build
   instead — `optimize/cosmopolitan.md` has the exact commands.)
2. **pick a target** (see `optimize/finding.md` and the backlog). state
   a hypothesis: *"X is slow because Y; changing Z should cut ns/op by
   W%."*
3. **change the code.** smallest diff that tests the hypothesis. follow
   every repo convention (AGENTS.md): Teal, 2-space indent, ≤500-line
   files, `value, string` error returns, wrappers keep their documented
   behavior and error messages.
4. **gate 1 — correctness and style:** `--make ci` must pass, run under
   the binary your change builds. the perf smoke test
   (`_perf/perf_test.tl`) runs every scenario end to end in CI, so a
   broken scenario check fails here too.
5. **gate 2 — performance:** re-measure and run `gate.tl compare` against
   your baseline. it uses a noise-aware bar
   (max of `--threshold`, baseline spread, current spread), retries
   once on failure to filter machine noise, and exits nonzero if any
   scenario regressed, errored, or disappeared. if a regression survives
   the retry it runs one more pass of the same binary and auto-triages:
   a scenario that also swings past the bar against itself is reported
   as `noise` and does not fail the gate, so a green `perf-compare` means
   "no regression the binary can reproduce against itself." trust the
   verdict — the manual A/A hunt is now built in.
6. **decide.**
   - target scenario improved beyond its noise bar and `perf-compare`
     exited 0 (no real regression; any `noise` rows already discounted)
     → keep it.
   - no measurable improvement, or a surviving `regression` row → `git
     checkout` the change and record the failed hypothesis. a surviving
     regression already reproduced against the binary itself, so it is
     real; do not re-litigate it as noise.
   - want to see the machine's noise floor yourself → `gate.lua
     selfcheck` runs the same A/A control on demand. see
     `optimize/measurement.md`.
7. **commit**, quoting before/after numbers for the affected scenarios in
   the commit message (copy the `perf-compare` lines), and update the
   backlog issue in the same round — comment the result and close it
   (completed, or "not planned" for a rejected hypothesis).

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
  change behavior are rejected by `--make ci` / scenario checks — fix
  the approach, not the test.
- one hypothesis per commit. if `--make ci` fails, you are done with
  that hypothesis until it passes; never trade correctness for speed.
- benchmarks live under `_perf/bench/` and use `cosmic.*` modules only
  (never raw `cosmo.*`) — they measure what users experience.

## running a research pass (re-seeding the backlog)

when the open backlog runs thin, spend a session on research instead of
optimization: gather evidence, write new `open` entries, change no
product code. the workflow that has worked (entries 22-27 came out of
one such pass):

1. run the harness on current main; read every line of the report.
2. rank suspects by the signal shapes in `optimize/finding.md`
   (alloc-per-op sanity math, sibling mismatches, cpu/wall surprises).
3. for each suspect, spend a few minutes reading the wrapper source —
   most hypotheses die or crystallize within one code read.
4. for startup/syscall suspects, use the tracing decomposition recipes
   in `optimize/cosmopolitan.md` (cosmo `--strace` call counting,
   kernel `strace -c`, raw-vs-wrapped binary timing).
5. cheap probes are allowed and encouraged — rebuild a variant
   artifact in a scratch directory and shell-time it (that's how the
   store-vs-deflate slice in entry 24 got real numbers) — but label
   probe numbers as scouting in the entry; accept/reject decisions
   still require the real harness.
6. one issue per hypothesis (label `perf`, in the repo whose layer it
   targets — whilp/cosmic or whilp/cosmopolitan), each with the
   evidence, the expected mechanism, the correctness constraints, and
   a risk note. update related older issues in the same pass
   (cross-reference by #number rather than duplicate).

## the hypothesis backlog

GitHub issues labeled `perf` hold the log — one issue per concrete,
evidence-backed starting point. open = unworked; closed as completed =
done; closed as "not planned" = a rejected dead end (kept forever, so
the next agent doesn't re-test it). cosmic-layer hypotheses live in
whilp/cosmic; cosmopolitan-layer ones in whilp/cosmopolitan. work it
like this: pick ONE open issue (`gh issue list --label perf --state
open`), run the loop above, then comment the result and close it in the
same round. each issue body carries the evidence, expected mechanism,
correctness constraints, and a risk note (issues migrated from the old
`_perf/backlog/*.md` files keep their "backlog entry N" numbering for
cross-references).

if a workload you want to optimize has no scenario, add one FIRST (in a
`_perf/bench/*_bench.tl` module, with a real `check()`), baseline it,
then optimize.
