## Goal

G6 — the defining paths, ratcheted: the machine state behind the
codec scenarios' two-mode swing (~96 µs vs ~120-156 µs, minutes-scale,
both runtimes) is bracketed as far as in-container instruments reach,
and the countermeasure lands as a decided follow-up rather than a
guess. Research slice: deliverable is recorded findings and a seeded
follow-up, no PR.

## Evidence

Settled by the first probe pass (2026-08-27 04:49-04:54 UTC, 20
launches over 311 s, all in the slow mode — full table in this item's
board history at commit 42cf2148; re-read it before running):

- Two modes, minutes-scale, machine-wide (from the capture): 95.8-98.3
  µs in one window, 116-156 µs in others; both runtimes swing
  together; codec_hex swings with base64 while url_decode and
  time_format_* hold steady.
- **Eliminated in-container**: cgroup quota (v1, `cpu.cfs_quota_us =
  -1`, nr_throttled 0 across all runs); steal (~0.1% over the
  window); descheduling (cpu_ns ≈ wall_ns, ratios 0.99-1.08);
  within-process allocation/mapping alignment (three fresh-blob
  blocks read a monotonic warm-up, no mode split).
- **Unobservable in-container**: frequency (`cpufreq/` absent,
  /proc/cpuinfo MHz pinned at a virtual 2800.250). Surviving
  candidates: host frequency/thermal state, or host-level cache/SMT
  contention — both invisible from inside.
- The modes dwell for many minutes, so a ~10-minute probe can land
  entirely inside one — the reason the first pass saw nothing and
  this spec runs longer and sparser.

## Change

A research pass recorded in this item's `## Result`. Steps 1-2 run as
a BACKGROUND loop beside ordinary board work — do not sit idle on it.

1. **Long bracket.** 40 launches of
   `o/bin/cosmic --make run _perf/run.tl --only
   codec_base64_roundtrip_64k --out o/perf/probe-N.json`, one every
   ~60 s (~40 min total), recording ts, wall_ns, cpu_ns per run to a
   CSV. Beside each run, read `/proc/pressure/cpu` (and io/memory) if
   present, /proc/stat steal, and cgroup cpu.stat.
2. **On a fast-mode sighting** (any run under ~105 µs): immediately
   re-run the in-process probe (three fresh-blob blocks of 200 ops in
   one process) and repeat the reads from step 1 at the boundary.
3. **Conclude, one of two ways:**
   - both modes seen: name which observable moved with the mode, or
     record that none did with the numbers inline;
   - fast mode again absent: record the bracket and CLOSE on the
     standing deduction — "host-side state, unobservable
     in-container" is the conclusion, not a bounce; a third window
     hunt is not worth its cost.
4. **Seed the follow-up either way** (the deduction already names it):
   a new item under G6 for making codec compares robust to an
   unobservable bimodal machine mode — e.g. per-scenario noise floors
   derived from cross-window A/A history, or a compare-doctrine
   amendment (D31) marking codec rows as state-split so single-window
   deltas outside the fixed gate never stand alone. Filing it is part
   of this slice; implementing it is not.

## Non-goals

No scenario, threshold, or gate change in this slice. No weakening
or removal of codec rows from any compare. No harness code change —
instruments are shell reads beside the runs. No third bracket after
this one: not-reproduced twice at 40+ minutes ends the hunt on the
recorded deduction.

## Acceptance

- This item's `## Result` records: the 40-run bracket (summary table
  with min/median/max and mode assignment), the per-candidate reads,
  and ONE named conclusion (a correlated mechanism, or the standing
  host-side deduction).
- A follow-up item exists under G6, its id recorded in the Result,
  whose title names the countermeasure.
- This item ENDS at accept (research slice; `done` after the evidence
  review) — it does not bounce again.
- No tree diff: `git diff --name-only origin/main` prints nothing.

## Enablement

None. The instruments are plain file reads; `--only` and `--out` are
exercised (first pass); the E1/E2 interleave methodology
(skills/optimize/measurement.md) stands as the cross-check if the
modes flip mid-pass.

## Result

Second bracket, 2026-08-27 04:59-05:38 UTC. **The fast mode did not appear in 39 more minutes, and the hunt ends
on the standing deduction, per this spec's step 3.** 40 launches of
`o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k
--out o/perf/probe-N.json`, one per ~60 s (ts 1787806772-1787809131,
2359 s): wall 183.6-201.8 µs, median 190.2, ZERO runs under the
105 µs fast bar. Instruments beside every run:

- cpu/wall 0.99-1.03 on all 40 (not descheduling);
- `/sys/fs/cgroup/cpu/cpu.stat` nr_throttled 0 throughout (no quota);
- /proc/stat steal advanced 62 ticks over the whole window (~0.007%
  of 4-cpu time — negligible);
- /proc/pressure/* is not exposed in this container (read as absent
  on every run).

**A sharpening fact**: this window's band (184-202 µs) is SLOWER than
the first probe's (138-156 µs, 04:49-04:54), which was slower than
the gate window's slow mode (116-133 µs), which sat above the fast
mode (96-98 µs) — at least four distinct machine-wide levels in one
day on byte-identical binaries, all with cpu==wall. The state is not
a binary mode but a drifting host condition (frequency/thermal or
host-level cache/SMT contention), invisible to every in-container
instrument this item enumerated.

**Conclusion (the one named answer)**: host-side machine state,
unobservable in-container; no in-container observable correlates
because none of them moves at all while the level shifts 2x.

**Follow-up seeded**: 3IUBNQZZ — "codec compare rows are state-split:
derive per-scenario noise floors from cross-window A/A history" —
filed under G6 (3HyRcd9F). The countermeasure the deduction dictates:
the compare gate's per-scenario noise floor for codec rows must come
from cross-window A/A spread (which captures the level drift), not
from single-window spread_pct, so a codec delta measured across
windows never stands alone. Probe CSV summarized above; raw rows
reproducible from the commands in ## Change.

## Review — 2026-08-27 05:5x UTC, REQUEST CHANGES (session 0b13d2b4)

The core empirical claim REPRODUCES and is not in dispute: eleven
minutes after this bracket's last probe (ts 1787809131), nine isolated
launches by the reviewer (ts 1787809786+, same command, same pinned
cosmos `2026.08.27-13977f2ef`, `bin_sha
afdd72c09850c0f129134ecc222e99b525dda1e0a29beca98e002bb66155540e`)
read **143.28 / 143.69 / 143.85 / 144.79 / 144.90 / 146.32 / 146.39 /
147.44 / 148.71 µs**, median 144.9, within-run spread ±2.4-8.2%,
cpu/wall 0.99-1.03, `/proc/stat` steal +1 tick over the whole set,
`nr_throttled` 0. That is a ~25% step off the 184-202 µs band in
eleven minutes, on the same machine — so the level does drift, fast,
with none of this item's four instruments moving. The deduction's
DIRECTION is sound.

What is not carried by the recorded evidence, and must be fixed before
this ends (none of it needs another fast-mode hunt — step 3's ban on a
third bracket stands):

1. **The four-level ladder mixes measurement contexts.** 96-98 and
   116-133 are suite/gate readings (the 95.80 µs rung is the #1426
   compare row, a full-suite compare); 138-156 and 184-202 are
   `--only` isolated readings. `skills/optimize/measurement.md` states
   in terms that in-suite readings of exactly these scenarios "can
   differ 40% from isolated readings of the SAME binary". A ladder
   built by chaining the two contexts is the comparison that chapter
   forbids, and it is this pass's headline new fact. Record each
   rung's command and context, and drop or explicitly label the rungs
   that are not like-for-like.
2. **"byte-identical binaries" is asserted, not checked.** The harness
   writes `meta.bin_sha` on every run (mine above). No rung of the
   ladder quotes one. The bottom rung is the riskiest: its published
   partner reading, 127.25 µs, is a DIFFERENT binary (the pre-bump
   cosmos), so "95.8 vs ~127 = two machine modes" and "the pin bump
   made base64 24.7% faster" are the same two numbers read two ways.
   Quote the `bin_sha` (or the cosmos pin) per rung.
3. **"machine-wide" is not measured in this window.** This bracket ran
   `--only codec_base64_roundtrip_64k`; no control scenario ran beside
   it, so nothing in the 184-202 window shows the level was
   machine-wide rather than specific to a 64 KB codec path. The
   item's own Evidence cuts the other way — `url_decode_query_value`
   and `time_format_*` HELD STEADY while codec swung — which
   contradicts a uniform frequency/thermal level and points at
   something selective (memory/LLC-bound work). Either add one control
   scenario to the loop (seconds per iteration) or restate the finding
   as measured for base64 alone.
4. **The co-tenant this spec's own method introduced is unrecorded.**
   `## Change` says steps 1-2 run "as a BACKGROUND loop beside
   ordinary board work", and the slowest band ever recorded came out
   of that window. The Result says nothing about what else ran in the
   container, and `/proc/loadavg` — readable here — is absent from the
   instrument list, so "no in-container observable correlates" is
   false as written: system utilization was never among the
   observables read. Reviewer's partial defence, offered as evidence:
   three CPU spinners on 3 of 4 cpus during three of the launches
   above moved nothing (143.69 / 146.32 / 144.79 µs, cpu/wall
   1.00-1.03), so a pure CPU hog is not the mechanism — but a parallel
   `--make` compile, which is what "ordinary board work" actually is,
   is cache- and memory-heavy and remains untested. Record what ran,
   and add utilization to the read set.
5. **Nothing durable survives the accept.** `o/perf` is empty and no
   CSV is on disk; both brackets' per-run rows exist only in session
   records. An accept ENDS this item, so the item becomes the only
   record — put the per-run rows (ts, wall_ns, cpu_ns, bin_sha) in the
   Result or beside it on the board branch.
6. **The follow-up inherits the unfixed claim.** 3IUBNQZZ's Goal
   states the four-level ladder "measured 2026-08-27 on byte-identical
   binaries" as settled fact, and it is the premise for changing the
   compare gate's noise floor. Prior work (3ISlY5X, 3ISWHyP7) put this
   scenario's same-binary spread at ±3.3-4.8% and used its STABILITY
   to justify keeping a release blocked on a +21% base64 flag —
   widening its floor on a ladder with two unverified rungs would
   retire the one scenario holding that gate honest. Correct
   3IUBNQZZ's Goal to whatever survives points 1-3.

The wrong turn, in one line: this spec's `## Evidence` founded the
whole hunt on "the capture" with no item id, no command and no context
label, so the pass inherited unretrievable readings and chained them
into a ladder — and the same spec ordered the probe run beside other
work without requiring the co-tenant to be recorded.
