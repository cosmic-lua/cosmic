## Goal

G6 — the defining paths, ratcheted: the machine state behind the
codec scenarios' two-mode swing (~96 µs vs ~120-133 µs, minutes-scale,
both runtimes) is IDENTIFIED, so codec rows in every future compare
carry an explanation instead of a shrug, and the countermeasure lands
as a decided follow-up rather than a guess. Research slice:
deliverable is recorded findings and a seeded follow-up, no PR.

## Evidence

Carried from the capture (2026-08-27, one container, nproc=4, all
values codec_base64_roundtrip_64k; commands and windows recorded
there):

- Two modes, minutes-scale, machine-wide: 95.8-98.3 µs in one window,
  116-133 µs in others; twelve consecutive launches across both
  runtimes all landed in the slow mode (04:07-04:12).
- BOTH runtimes swing together and codec_hex swings with base64,
  while url_decode_query_value and time_format_* held steady across
  the same windows — the state is not a global clock artifact.
- `cpu/wall` prints ~1.00-1.01 for these scenarios (harness.tl:254,
  the run log's own column), so the swing is not descheduling alone —
  cpu_ns moves with wall_ns. That already disfavors "gate on cpu_ns"
  as the countermeasure and points at frequency, thermal or cache/
  alignment state.
- The in-image loop pins (cosmopolitan #281/#282) hold by
  construction; a fixed binary's layout cannot drift between
  launches.

## Change

A research pass, run inside one container session, recorded in this
item's `## Result`:

1. **Reproduce and bracket the modes.** Loop
   `bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k
   --out o/perf/probe-N.json` (or the harness's narrowest equivalent —
   record the exact flag) ~20 times over ~10 minutes; record per-run
   wall_ns, cpu_ns, and timestamp. The two modes must appear, or the
   finding is "not reproduced in this window" and the item bounces
   back to plan with that recorded.
2. **Instrument the candidates, same loop:**
   - frequency: read
     `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` (and
     `/proc/cpuinfo` MHz) immediately before and after each run;
     absent files are themselves a finding (container may hide them).
   - quota/steal: `/sys/fs/cgroup/cpu.stat` (or cpu.max) deltas per
     run; `/proc/stat` steal column.
   - alignment: within one process, run the scenario body twice with
     the 64KB buffers allocated fresh each time; a bimodal
     WITHIN-process split implicates allocation/mapping alignment,
     a stable within-process value implicates host state.
3. **Correlate and conclude.** The Result names which observable
   moves WITH the mode (or that none do, which is its own finding),
   with the numbers inline.
4. **Seed the follow-up** as a new item under G6: the countermeasure
   the mechanism dictates — e.g. record the observable in each run's
   `meta` so compares can annotate codec rows (harness change), or a
   D-record amending the compare doctrine for state-split scenarios.
   Filing it is part of this slice; implementing it is not.

## Non-goals

No scenario, threshold, or gate change in this slice. No weakening
or removal of codec rows from any compare. No harness code change
yet — instruments here are shell reads beside the runs, so the
follow-up starts from an identified mechanism, not before.

## Acceptance

- This item's `## Result` records: the mode bracket (per-run table or
  summary), the per-candidate correlation observations with their
  read commands, and ONE named conclusion (a mechanism, or "none of
  the three candidates correlates" with the data shown).
- A follow-up item exists under G6 (id recorded in the Result) whose
  title names the countermeasure the conclusion dictates — or, on a
  not-reproduced outcome, this item is back in plan with the window
  recorded.
- No tree diff: `git diff --name-only origin/main` prints nothing.

## Enablement

None. The instruments are plain file reads; the harness already
records cpu_ns and wall_ns per scenario (_perf/harness.tl:187), and
`_perf/run.tl` accepts `--out` per run. The E1/E2 interleave
methodology (optimize skill, measurement.md) stands as the
cross-check if the modes flip mid-pass.

## Result (2026-08-27 04:49-04:54 UTC — not reproduced in this window;
back to plan per step 1)

**The fast mode did not appear.** 20 launches of
`o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k
--out o/perf/probe-N.json`, one every ~16 s over 311 s
(ts 1787806169-1787806480): wall 138.5-156.0 µs, median ~141.5 µs —
every run in the slow mode, matching the capture's own twelve-launch
slow streak (04:07-04:12). The modes dwell for many minutes at a
time, so a ~10-minute probe can land entirely inside one; the next
attempt should either run longer (30+ min, sparser) or trigger on a
fast-mode sighting in ordinary work.

**What the instruments said anyway (all read beside each run):**

- **Frequency is unobservable from this container**:
  `/sys/devices/system/cpu/cpu0/cpufreq/` does not exist, and
  `grep "cpu MHz" /proc/cpuinfo` prints a pinned 2800.250 on all 4
  CPUs on every read — a virtual constant, not a measurement. The
  frequency/thermal candidate can therefore never be confirmed or
  cleared from inside; only correlation with an external observable
  could.
- **Throttling cannot be the mechanism here**: cgroup v1,
  `cpu.cfs_quota_us = -1` (no quota), and
  `/sys/fs/cgroup/cpu/cpu.stat` nr_throttled stayed 0 through all 20
  runs.
- **Steal is negligible**: /proc/stat steal advanced 99→103 ticks
  over the whole window (~0.1% of 4-cpu time).
- **cpu_ns ≈ wall_ns on every run** (ratios 0.99-1.08, one outlier
  run 12 at 1.08), reconfirming the capture: not descheduling.
- **No within-process bimodality**: three fresh-blob blocks of 200
  ops in one process (04:50) read 164.9 / 153.8 / 146.7 µs/op — a
  monotonic warm-up, no mode split — so allocation/mapping alignment
  inside a process is disfavored; the state is host-side.

**Deduction left standing for the next window**: with quota off,
steal flat, cpu==wall, and layout pinned in-image (#281/#282), the
surviving candidates are host frequency/thermal state or host-level
cache/SMT contention — both invisible to in-container instruments.
Any future fast-mode window should immediately re-run the in-process
probe and the same reads, and grab /proc/pressure/* if present.
Probe script and CSV preserved in the session record; the CSV is
quoted above in summary and the raw rows are reproducible from the
commands in ## Change.
