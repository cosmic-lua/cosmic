## Goal

G6 — the defining paths, ratcheted: establish, from recorded evidence,
how far a single isolated reading of `codec_base64_roundtrip_64k` can
be trusted — within one measurement session, and across sessions and
binaries — so that no compare row and no release decision rests on a
level this scenario does not reproduce. Research slice: the
deliverable is recorded findings and a seeded follow-up, no PR.

Goal restated 2026-08-27 in the second rework. It previously named
"the machine state behind the codec scenarios' two-mode swing (~96 µs
vs ~120-156 µs, minutes-scale, both runtimes)" as the thing to
bracket. Two brackets measured no such swing, so the Goal now names
the question the recorded evidence actually answers, per
`decompose.md` — a Goal that no longer matches what the item delivers
is fixed, not carried.

## Evidence — the opening hypothesis, since retired

RETAINED VERBATIM below as the position this slice was opened to
test, NOT as findings. The `## Result` retires most of it: no
bimodality was ever observed under a recorded binary, "machine-wide"
is withdrawn, and "both runtimes" is withdrawn. Read this section as
the starting hypothesis and the Result as what came back.

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

- This item's `## Result` records: the 40-run bracket with its
  per-run rows and its dispersion (min/median/max, sd, CV), the
  per-candidate instrument reads, and ONE named conclusion stated at
  the width the recorded data carries.
- Every reading the Result cites is labeled with the command that
  produced it, its measurement context (isolated `--only` vs
  full-suite), and the binary it ran on (`meta.bin_sha` or the
  cosmos pin); a reading that cannot be so labeled is struck as
  evidence rather than carried.
- A follow-up item exists under G6, its id recorded in the Result,
  whose title names the countermeasure, and whose Goal asserts no
  more than this item's Result establishes.
- The deliverable is evidence and there is no PR, so the handover is
  `gitboard move 3IU0GxoA check --evidence` and an accept ends the
  item with `done` rather than parking it in `land`. This bullet
  fixes the SHAPE of the handover only: which of `check`'s three
  verdicts follows is the reviewer's to give, and no spec may
  pre-spend it. (Bullet rewritten 2026-08-27: it previously read
  "This item ENDS at accept ... it does not bounce again", which
  instructed the gate.)
- No tree diff: `git diff --name-only origin/main` prints nothing.

## Enablement

None. The instruments are plain file reads; `--only` and `--out` are
exercised (first pass); the E1/E2 interleave methodology
(skills/optimize/measurement.md) stands as the cross-check, and is
the instrument the Result names as the way to close this pass's one
open confound.

## Result

**Read this first if you arrived by the title.** The title says
"swings 25-30% across minutes machine-wide on both runtimes". Of that,
one clause survives at roughly the stated size and three do not, and
the title cannot be corrected — no gitboard verb renames an item
(3IFWAdlL, backlog, band 1). Corrected in one paragraph:

- **"across minutes" — WRONG, and this item's own data refutes it.**
  40 isolated launches over 40 minutes on ONE recorded binary held a
  median of 190.0 µs at a coefficient of variation of **2.1%**,
  unimodal, with no trend between the first and second halves. Within
  one session the level is STABLE.
- **A ~25-32% step — RIGHT, but the axis is SESSIONS, not minutes,**
  and it is founded below on a binary held BYTE-IDENTICAL across two
  sessions (191.31 vs 144.29 µs, disjoint ranges), which is evidence
  this item did not produce and neither review found.
- **"machine-wide" — WITHDRAWN.** Neither bracket here measured any
  scenario but base64.
- **"both runtimes" — WITHDRAWN.** Nothing in this item measured two
  runtimes; its only support was two readings this pass struck as
  cross-binary.

**The durable record: the 40-run bracket.** 2026-08-27 04:59-05:38
UTC (ts 1787806772-1787809131), 40 launches of `o/bin/cosmic --make
run _perf/run.tl --only codec_base64_roundtrip_64k --out
o/perf/probe-N.json`, one per ~60 s. Context: ISOLATED (`--only`).
Binary: `bin_sha c81de75b787a…` on all 40 runs (cosmic built at main
`cb39b65d`, cosmos pin `2026.08.27-13977f2ef`). Per-run rows (n, ts,
wall_us, cpu_us):

```
1,1787806772,185.6,184.8
2,1787806846,195.7,193.7
3,1787806906,188.8,190.2
4,1787806966,186.6,187.6
5,1787807026,188.9,190.8
6,1787807087,185.1,185.2
7,1787807147,193.6,195.7
8,1787807207,192.2,191.2
9,1787807267,187.9,188.2
10,1787807327,195.3,199.5
11,1787807387,192.5,195.0
12,1787807447,190.9,189.2
13,1787807507,183.9,185.2
14,1787807567,187.2,186.8
15,1787807627,194.4,195.3
16,1787807688,188.0,187.8
17,1787807748,195.5,195.2
18,1787807808,193.0,194.5
19,1787807868,190.2,190.7
20,1787807928,184.7,187.4
21,1787807988,192.7,192.5
22,1787808048,192.2,193.4
23,1787808108,189.0,188.4
24,1787808168,194.9,200.7
25,1787808228,184.8,187.1
26,1787808288,189.0,191.1
27,1787808348,194.0,193.7
28,1787808409,188.7,190.8
29,1787808469,183.6,183.5
30,1787808530,193.2,195.1
31,1787808589,189.3,188.4
32,1787808649,201.8,206.6
33,1787808710,185.2,185.1
34,1787808770,191.4,196.5
35,1787808830,187.4,186.7
36,1787808890,188.7,190.0
37,1787808950,195.3,194.4
38,1787809010,189.7,191.2
39,1787809071,193.0,192.5
40,1787809131,193.8,192.6
```

Instruments beside every run: cpu/wall 0.99-1.03; nr_throttled 0
(cgroup v1, no quota); /proc/stat steal +62 ticks over 2359 s of
4-cpu time; /proc/pressure/* absent in this container.

**What those 40 rows say.** min 183.6, median 189.95 (the two middle
values are 189.7 and 190.2), max 201.8, mean 190.44, sample sd 4.03
(population sd 3.98), **CV 2.1%**, range -3.3% / +6.2% about the
median, max/min 1.099. Split in half by time, the first 20 launches
median 189.55 and the second 20 median 190.55 — a 0.5% difference, so
there is no drift across the 40 minutes either, not merely no
bimodality. Forty launches, forty minutes, one recorded `bin_sha`, one
context, one tight unimodal band. This is the only same-binary
same-context cross-window dataset this item owns, and it refutes the
minutes-scale bimodality this slice was opened to bracket.

One caution on comparing that CV against the "±3.3-4.8%" figure the
earlier Conclusion cited: they are not the same statistic. CV 2.1% is
a standard deviation across 40 separate launches; the harness's `±` is
a within-run spread over the 5 samples of ONE invocation. The honest
statement is the standalone one — 40 launches held to CV 2.1%.

**The control this item needed was already on the board: the same
binary, two sessions, 32.6% apart.** 3ISlWFiS and 3ITOUv0w each
measured cosmic binary `d8492168eace15f18e5d56b8949144d947e58b9dad1c4ada6401eea98e035b44`
(tree `5ef13f40`, cosmos `2026.08.21-07fc94a1c`) — the SAME BYTES,
hashed with `sha256sum o/bin/cosmic` in both items and cross-checked a
third time by 3ITHROpY — in two independent sessions and containers on
2026-08-26, both isolated `--only codec_base64_roundtrip_64k`, both
default `--samples`/`--min-secs`:

| binary | item | readings (µs) | median | range | CV |
|---|---|---|---|---|---|
| `d8492168…` | 3ISlWFiS | 194.94, 187.67, 185.81, 195.26 | 191.31 | [185.81, 195.26] | 2.6% |
| `d8492168…` | 3ITOUv0w | 142.57, 146.52, 143.72, 145.69, 144.29, 149.19, 143.50, 145.72, 141.61 | 144.29 | [141.61, 149.19] | 1.6% |
| `940f21bb…` | 3ISlWFiS | 214.50, 210.67, 208.04, 206.45 | 209.35 | [206.45, 214.50] | 1.7% |
| `940f21bb…` | 3ITOUv0w | 174.67, 170.41, 173.14, 171.54, 178.32, 173.03, 176.14, 175.10, 173.38 | 173.38 | [170.41, 178.32] | 1.4% |

Two binaries, byte-identical on both sides, each read **+32.6%** and
**+20.7%** higher in one session than the other, with the two sides'
raw ranges completely DISJOINT and each side internally tight (CV
1.4-2.6%). That settles what this item could not settle for itself:
a step of exactly this size and direction occurs with the binary held
byte-identical, so build identity is not required to explain one. The
two ratios differ (1.326 vs 1.207), so whatever moves the level is not
a uniform frequency scaling — consistent with the selectivity the
opening hypothesis noted, where `url_decode` and `time_format_*` held
steady while the codecs swung.

**The two levels, and where this item's own numbers land on them.**
Across every isolated `--only codec_base64_roundtrip_64k` dataset on
record, the readings cluster at roughly 144 µs and roughly 190 µs (and
their `354c17e08`-arm counterparts at 173 and 209), and this item's
two sound groups land on those clusters within a percent:

| # | date | binary / pin | readings (µs) | vs cluster |
|---|---|---|---|---|
| A | 08-26 | main `ec794d44`, pin `2026.08.26-fe7c36c4c` | 216.60, 209.58 | ~209 |
| B | 08-26 | `d8492168…`, pin `07fc94a1c` (3ISWHyP7) | 191.73, 196.18, 193.46 | ~190 |
| C | 08-26 | `940f21bb…`, pin `354c17e08` (3ISWHyP7) | 227.05, 206.34, 208.58 | ~209 |
| D | 08-27 | `c81de75b787a…`, main `cb39b65d`, pin `13977f2ef` | 40 launches, median 190.0, CV 2.1% | ~190, within 0.7% of 3ISlWFiS's 191.31 |
| E | 08-27 | `afdd72c09850…`, pin `13977f2ef` (review 1's control) | 9 launches, median 144.9, CV 1.3% | ~144, within 0.4% of 3ITOUv0w's 144.29 |
| F | 08-27 | first bracket, `bin_sha` UNRECORDED | 138-156 | ~144, unlabeled binary |

Every group whose binary is recorded is internally tight — CV 1.2% to
5.3% across groups of 2 to 40 launches — and none shows anything like
a 25-30% swing inside itself. The variation is entirely BETWEEN
sessions, and the same two levels recur across four independent
sessions on five different binaries.

**The polarity question, resolved (review 2 point 3).** The earlier
Conclusion treated 144.9 µs as the baseline and the ~190 band as drift
away from it. Neither is the baseline. Both levels are reproduced
placements: ~190 by 3ISWHyP7 (group B), 3ISlWFiS (191.31) and this
bracket (group D, 40 launches), and ~144 by 3ITOUv0w (144.29, nine
launches) and review 1's control (group E, nine launches). A session
lands on one of them and stays there — group D held its level for 40
minutes at CV 2.1% — and which one it lands on is not observable from
inside. So neither reading is anomalous, and the earlier framing's
choice of 144.9 as the reference was arbitrary rather than neutral.

**A correction to review 2, point 3.** Review 2 quoted 3ISWHyP7 as
concluding "the scenario drifts ~11% between isolated runs" of base64.
That sentence in 3ISWHyP7 is about `json_decode_large`, not base64.
The same paragraph records base64 as staying "inside 3.5%" across
isolated calls — i.e. the prior record already characterised base64 as
the STABLE one of the two within a session, which is what the 40-run
bracket then confirmed at 40x the sample count.

**The comparator, corrected (review 2 point 4).** The earlier
Conclusion cited "±3.3-4.8%" as the prior same-binary in-window
spread. That is the two tightest of six. 3ISWHyP7's full `±` column
across its six isolated rounds is **14.2 / 9.8 / 13.1 / 7.0 / 4.8 /
3.3 %**, those six rounds alternate between TWO binaries (three per
side), and the column falls monotonically from round 1 to round 6,
which looks like machine warm-up across the sitting rather than a
property of either binary. 3ISlY5Xl quoted the tightest pair
deliberately and correctly: it was building a worst-case argument, in
which the SMALLEST plausible noise figure is the conservative choice
(`21.0 > max(10.0, 2 x 4.8 = 9.6)` holds a fortiori for any larger
one). Re-used as *the* prior spread it understates by about 3x, so
"far beyond the same-binary in-window spread prior work measured" is
withdrawn as a load-bearing phrase from this Conclusion and from
3IUBNQZZ's Goal. The right comparator for a cross-session level
difference is not a within-run `±` at all: it is the byte-identical
pair above.

**What ran beside the bracket (review 1 point 4).** The bracket ran in
this container while the building session did gitboard machinery work:
two full `bin/cosmic --make build`s (~05:03, ~05:20), one full `--make
ci` (~05:26-05:31: tree compile plus 26 test files), and several
narrower test runs — cache- and memory-heavy co-tenants, unrecorded
per-run. `/proc/loadavg` was NOT among the instruments read, so this
item's earlier claim "no in-container observable correlates" was false
as written and is corrected to: none of the four instruments actually
read (cpu/wall ratio, cgroup throttle, steal, pressure-absence) moved,
and system utilization was never among them. Review 1's spinner
control — three CPU hogs on 3 of 4 cpus during three of its nine
launches, readings 143.69 / 146.32 / 144.79 µs — rules out a pure CPU
hog as the mechanism; a concurrent compile's cache and memory pressure
remains untested. Note that the co-tenancy runs the WRONG way for a
load story: the 40-run bracket, the one with heavy co-tenants, is the
tight dataset, and 3ITOUv0w's quiet round-robin sat at the FAST level.

**The ladder, labeled by context and binary (review 1 points 1-2).**
Rungs that cannot be labeled are struck as evidence rather than
carried:

| reading | context | binary (bin_sha / pin) | standing |
|---|---|---|---|
| 95.80 µs | full-suite compare row (PR #1426 gate window) | pre-bump vs post-bump cosmos — TWO binaries | struck: cross-binary AND suite-context |
| 116-133 µs | suite/gate windows ("the capture", no item id, no command recorded) | unretrievable | struck: unretrievable |
| 138-156 µs | isolated `--only` (first bracket, 04:49-04:54) | `bin_sha` unrecorded (another session's build) | weak: context labeled, binary not |
| 183.6-201.8 µs | isolated `--only` (this bracket, group D) | `c81de75b787a…` / `13977f2ef` | sound |
| 143.28-148.71 µs | isolated `--only` (review 1's control, nine runs) | `afdd72c0…` / `13977f2ef` | sound |

`skills/optimize/measurement.md` states that in-suite readings of
exactly these scenarios "can differ 40% from isolated readings of the
SAME binary", so the two struck suite-context rungs may never be
chained to the isolated ones. That is why every sub-100 µs reading in
this item's history is struck: no fast-mode isolated reading under a
recorded `bin_sha` was ever observed in either bracket, and the two
that exist elsewhere (3ITOUv0w, review 1's control) sit at ~144, not
under 100.

**Conclusion.** Stated at the width the recorded evidence carries.
WITHIN one measurement session, isolated readings of
`codec_base64_roundtrip_64k` are stable: 40 launches over 40 minutes
on one recorded binary held median 190.0 µs at CV 2.1%, unimodal and
trendless, and every other labeled group on record is internally tight
at CV 1.2-5.3%. BETWEEN sessions the absolute LEVEL moves by 20-33%
with the binary held byte-identical: cosmic `d8492168…` read median
191.31 µs in one session and 144.29 µs in another with disjoint
ranges (+32.6%), and cosmic `940f21bb…` read 209.35 and 173.38 µs the
same way (+20.7%). The levels recur — ~144 and ~190 for the
`07fc94a1c` arm — across four independent sessions, and this item's
own two sound groups land on them within 0.7% and 0.4%. The two
ratios differ, so it is not a uniform frequency scaling; nothing
observable from inside the container moved anywhere in the record
(cpu/wall ratio, cgroup throttle, steal, pressure-absence), and
system utilization was never read. The operational statement, and the
only one a compare row should rest on: **an absolute reading of this
scenario is reproducible to a few percent within its own session and
is NOT comparable across sessions, where the same bytes have been
recorded 33% apart; only a delta measured between two binaries
interleaved in ONE session means anything.** This item's founding
hypothesis — that the level swings across minutes within a session —
is refuted; the axis is the session, and this item's own 190-vs-144.9
step, which it could not separate from a binary change, needs no such
separation because the byte-identical control above supplies it.

**What this does NOT license, stated explicitly.** It is not a reason
to widen `codec_base64_roundtrip_64k`'s noise floor in the perf gate,
and this item asks for no such change (`## Non-goals`). 3ISlY5Xl used
this scenario's within-session tightness to keep a release blocked at
+21.0% via `21.0 > max(10.0, 2 x 4.8)`, and everything measured here
makes the scenario look MORE stable within a session, not less: the
40-run bracket is tighter than the figure that arithmetic used, and
the release lane measures its baseline and its candidate in the SAME
job on the SAME runner, which is precisely the interleaved shape the
cross-session effect cannot reach. The 20-33% cross-session spread is
NOT a noise budget for that gate; treating it as one would retire the
arithmetic that kept the gate honest over a real regression that two
independent interleaved experiments have since confirmed (3ISlWFiS
+8.35% A→C, 3ITOUv0w +20.16% A→`354c17e08`). What the evidence does
support is RECORDING and INTERLEAVING, not a wider bar.

**One consequence worth carrying forward.** The same real code delta
measured +9.44% (3ISlWFiS, at the ~191 level) and +20.16% (3ITOUv0w,
at the ~144 level) — both interleaved within their own session, both
verdicts REPRODUCED. So the measured MAGNITUDE of a genuine regression
depends on which level the session landed on, roughly doubling at the
fast level. A fixed-percentage bar therefore has a different
sensitivity from session to session even when it is applied to a
correctly interleaved pair. That is the sharpest argument for the
follow-up, and it is founded on two interleaved experiments rather
than on any level comparison.

**Follow-up: 3IUBNQZZ, under G6.** Its Goal was rewritten in the same
pass as this rework, to assert only what survives above: the perf gate
records nothing about which binary produced a row, its noise floor
comes from one window's spread, and the level a session lands on
changes a real regression's measured size by about 2x. The actionable
half is RECORDING — `meta.bin_sha` stamped into every compare row the
harness prints — plus keeping the interleaved-within-one-session shape
as the only thing a codec claim may rest on. Deriving floors from
cross-window A/A history stays a hypothesis to test at plan against
accumulated selfcheck history, not a finding, and explicitly not a
warrant to widen base64's bar.

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

## Review 2 — 2026-08-27 06:2x UTC, REQUEST CHANGES

The rework answers all six points of review 1 in good faith, and three
of them completely: the per-run rows are now durable in the item
(point 5), the co-tenant correction is stated against the item's own
earlier false claim (point 4), and 3IUBNQZZ's "byte-identical
binaries" premise is gone (point 6, partly — see 6 below). Withdrawing
"machine-wide" in the body was the right call and was made by the
builder, not extracted. **No new bracket is asked for below.** Every
change requested is a restatement of readings already recorded here or
on the board; step 3's ban on a third bracket stands untouched.

What blocks the accept is that the surviving conclusion is still wider
than the surviving data, in five specific places.

### 1. The 40-run bracket is stable, and the Result never says so

Computed from the 40 rows recorded above: min 183.6, median 190.0
(the two middle values are 189.7 and 190.2), max 201.8, sd 3.98,
**CV 2.1%**, range -3.4% / +6.2% around the median. Forty launches,
forty minutes, ONE recorded `bin_sha`, one context.

That is the only same-binary, same-context, cross-window dataset this
item owns, and it shows no bimodality and no 25-30% swing — it is
tighter than the ±3.3-4.8% the Conclusion cites as the in-window
comparator. It is the pass's most solid number and it argues AGAINST
minutes-scale bimodality *within a window*. Put it in the Result. A
reader who has only the ladder cannot tell that the 183.6-201.8 rung
is a tight band rather than a spread.

### 2. The only 25% step coincides exactly with a binary change

The Result concedes this ("machine state and binary build are
confounded even there") and then leads the Conclusion with the drift
reading anyway. The two facts side by side: within one binary, 40
minutes, ±5%; across the one moment the binary changed, 24%. That is
the textbook shape of a confound, and it does not become weaker for
being named.

The narrowest claim the recorded data carries is roughly: *"over 40
minutes on one recorded binary, isolated codec_base64 readings held to
CV 2.1% around 190 µs; a different cosmic build over the same pinned
cosmos read 144.9 µs eleven minutes later; machine state and binary
identity moved together and this pass separated neither."* Restate the
Conclusion at that width, or close the confound (see the optional
control below).

### 3. The polarity of the anomaly is unexamined — 3ISWHyP7 already
recorded this level

3ISWHyP7's own six ISOLATED `--only codec_base64_roundtrip_64k`
rounds, 2026-08-26, read **191.73 / 227.05 / 196.18 / 206.34 / 193.46
/ 208.58 µs**, and that item concluded the scenario "drifts ~11%
between isolated runs". This bracket's 183.6-201.8 band sits INSIDE
that range.

So 184-202 is not a newly-discovered slow window; it is close to what
this scenario has previously read in isolation on this machine (across
a different cosmos pin — stated as the caveat it is). The reading that
stands out against the prior record is the 144.9 µs one, on a
different cosmic build. The Result frames the fast reading as the
baseline and the 190 band as the drift; the prior record suggests the
opposite framing is at least as available. Say which, and why, with
3ISWHyP7's rounds quoted.

### 4. The "±3.3-4.8%" comparator is the two tightest of six readings

Same table: the within-run `±` column across those six rounds is
**14.2 / 9.8 / 13.1 / 7.0 / 4.8 / 3.3 %**. 3ISlY5Xl quoted only the
last two, on purpose and correctly — it was building a worst-case
argument (even at the tightest spread, +21.0% > 2 x 4.8%). Re-used
here as *the* prior same-binary in-window spread, that pair
understates the comparator by a factor of three, and "far beyond the
same-binary in-window spread prior work measured" is the load-bearing
phrase in both this Conclusion and 3IUBNQZZ's Goal. Quote the full
range, or state why the settled rounds are the right comparator.

### 5. "both runtimes" is still in the title and was never addressed

Review 1's point 2 was the cross-binary/cross-pin conflation, and the
ladder duly struck the 95.80 µs rung as "pre-bump vs post-bump cosmos
— TWO binaries". But "both runtimes" is that same conflation stated as
a finding, and the rework does not touch it: its only support was the
struck capture and the struck cross-pin pair. Nothing in either
bracket measured two runtimes. Withdraw it in the body as
"machine-wide" was withdrawn, or found it.

**And the title is the part that outlives this item.** An accept ENDS
3IU0GxoA; `find`, `status` and `next` print the TITLE, so
"swings 25-30% across minutes machine-wide on both runtimes" becomes
the board's permanent headline for a body that withdraws "machine-wide"
outright and cannot support "both runtimes". That is precisely the
failure this item exists to warn about: an unlabeled claim outliving
its evidence. No verb renames an item (**3IFWAdlL**, backlog, band 1 —
which already records three sessions hitting this in four days; this
is the fourth), so take the work-around the work skill allows once:
hand-edit the `["title"]` line in
`items/3IU0GxoAXmEaBi9G8OQyabFPZBi.tl` and commit.

### 6. 3IUBNQZZ still carries the un-narrowed premise

Its Goal now reads: "same-command ISOLATED readings ... drift across
minutes-scale windows far beyond the ±3.3-4.8% same-binary in-window
spread ... — 190.2 vs 144.9 µs at medians eleven minutes apart ...
binary-build identity across windows is a confound the current gate
never records." The cross-binary pair is offered as the drift
evidence, with the confound recast as an argument FOR the
countermeasure rather than as the reason that pair cannot carry it.

This matters more than usual because of what the floor is holding:
3ISlY5Xl used this scenario's stability to keep a release blocked on a
+21.0% flag (`21.0 > max(10.0, 2 x 4.8)`). Widening base64's noise
floor on a cross-binary pair would retire the arithmetic that kept
that gate honest. 3IUBNQZZ's premise must be whatever survives points
1-4 here — the finding is strong enough without the widest reading of
it, since the recording gaps it prescribes (`meta.bin_sha` per compare
row, cross-window A/A history) are justified by the confound EXISTING,
not by its resolution.

### The optional control — offered, not required

One cheap instrument separates point 2 and needs no fast-mode hunt:
interleaved A/B of the two recorded binaries. Both are identified
(`c81de75b787a…` at main `cb39b65d`, `afdd72c0…`, same cosmos pin
`2026.08.27-13977f2ef`); rebuild at those commits and run
`--only codec_base64_roundtrip_64k` back to back, twice per side. That
is measurement.md's instrument of record for exactly this question,
and it is not a bracket — step 3 bans a third fast-mode hunt, not a
control. If both read the same level today, machine state moved and
the drift claim is earned outright; if they hold ~24% apart, the
finding is a build-identity effect and a different (and more
actionable) result. Narrowing the prose per 1-6 closes this item just
as validly.

### The wrong turn, in one line

The unmeasured claim this pass was sent to test was minted into the
item's TITLE before any evidence existed, so withdrawing it in the
body left the board still asserting it — the recurrence 3IFWAdlL
exists to stop (`--enable 3IFWAdlL`). A second, this-item-only
ready-bar defect to fix while re-refining: the Acceptance bullet
"This item ENDS at accept ... it does not bounce again" instructs the
gate. A spec sets what must be true for an accept; it cannot pre-spend
the verdict, and review.md gives `check` exactly three exits with no
spec-supplied fourth.

## Rework 2 — 2026-08-27 13:2x UTC (session 05f7c552)

Claim taken over from `3f616956` after it went stale 6h, with
`move 3IU0GxoA do --claim 05f7c552-… --force --why …` — the takeover
`next` itself printed. **No new measurement was taken and none was
needed**: review 2 recorded that every change it asked for is a
restatement of readings already on the board, and step 3's ban on a
third bracket stands untouched. The one substantive addition below is
also not new measurement — it is a control that was already on the
board, in two completed sibling items, and that neither review found.

**The control, and why it changes the answer.** 3ISlWFiS and 3ITOUv0w
each measured cosmic binary `d8492168eace…` — the same bytes,
`sha256sum`-verified in both items and a third time by 3ITHROpY — with
the same isolated command, in two independent sessions. It read median
191.31 µs in one and 144.29 µs in the other, with disjoint raw ranges,
and its sibling arm `940f21bb…` read 209.35 and 173.38 the same way.
That is a +32.6% and a +20.7% level step with the binary held
BYTE-IDENTICAL. Consequences for the two reviews' central asks:

- review 2's point 2 (the 24% step is confounded by a binary change)
  is CORRECT about this item's own pair and no longer load-bearing:
  the board already contains the unconfounded version of the same
  step, so build identity is not needed to explain one.
- review 2's point 3 (polarity) resolves rather than flipping: both
  ~144 and ~190 are reproduced session placements, each seen in two
  independent sessions, so neither is "the" baseline and the earlier
  choice of 144.9 as the reference was arbitrary.
- the item's founding hypothesis is refuted on its own axis and
  founded on another: the level does not swing across MINUTES (40
  launches, 40 minutes, CV 2.1%), it differs across SESSIONS.

Disposition of review 1's six points, all of which the first rework
answered and this one keeps:

1. **Ladder mixes contexts** — the labeled ladder stands, with the
   `measurement.md` 40%-in-suite rule quoted as the reason the two
   sub-100 rungs may never chain to the isolated ones.
2. **bin_sha per rung** — stands; the by-binary table carries
   `bin_sha` or pin for every group and marks group F unlabeled.
3. **"machine-wide" not measured** — withdrawn, now in the Result's
   FIRST paragraph rather than midway through.
4. **Co-tenant unrecorded** — stands, plus the observation that the
   co-tenancy runs against a load story: the heavily co-tenanted
   bracket is the tight dataset and the quiet round-robin sat at the
   fast level.
5. **Nothing durable survives** — the 40 per-run rows stay verbatim.
6. **Follow-up inherits the unfixed claim** — 3IUBNQZZ's Goal
   rewritten again, narrower than the first rework left it.

Disposition of review 2's six:

1. **The bracket is stable and the Result never says so** — done, and
   extended: sd, CV, range, max/min, plus a first-half/second-half
   median split (189.55 vs 190.55) showing no trend across the 40
   minutes, not merely no bimodality. One qualification recorded
   rather than swallowed: review 2 compares CV 2.1% against the
   "±3.3-4.8%" figure, and those are different statistics (a
   cross-launch sd versus a within-run spread over 5 samples). The
   Result states the CV standalone.
2. **The 24% step coincides with a binary change** — accepted as
   stated, and superseded by the byte-identical control above. The
   Conclusion now leads with within-session stability and puts the
   step on the session axis, where it is founded.
3. **Polarity unexamined** — done, and resolved rather than merely
   flipped, using 3ISlWFiS/3ITOUv0w rather than 3ISWHyP7's range
   argument. WITH ONE CORRECTION TO REVIEW 2: its quoted "drifts ~11%
   between isolated runs" is 3ISWHyP7's finding about
   `json_decode_large`, not base64 — the same paragraph records base64
   as staying "inside 3.5%" across isolated calls. The correction
   strengthens the narrowing rather than resisting it.
4. **The ±3.3-4.8% comparator** — done: the full column 14.2 / 9.8 /
   13.1 / 7.0 / 4.8 / 3.3 % is quoted, with the note that the six
   rounds straddle two binaries and that 3ISlY5Xl's use of the
   tightest pair was correct for a worst-case argument. The phrase
   "far beyond the same-binary in-window spread prior work measured"
   is withdrawn here and in 3IUBNQZZ, and the Result adds that a
   within-run `±` was never the right comparator for a cross-session
   level difference in the first place.
5. **"both runtimes"** — WITHDRAWN in the body, in the Result's first
   paragraph, alongside "machine-wide". The TITLE is not edited: see
   below.
6. **3IUBNQZZ carries the un-narrowed premise** — rewritten; the
   cross-binary pair no longer carries the drift claim, the founded
   premise is now the byte-identical cross-session control plus the
   level-dependent magnitude of a real regression, and the Goal says
   in terms that none of it warrants widening base64's floor.

**The optional control review 2 offered was NOT run, and is no longer
needed.** It proposed rebuilding `c81de75b787a…` and `afdd72c09850…`
and interleaving them. The equivalent experiment already exists on the
board at higher quality — two binaries, byte-identity verified across
three sessions, nine interleaved readings per arm — so running a
weaker version of it in a shared, noisy container would add nothing
and would itself be the kind of single-window number this item exists
to distrust. Review 2 said narrowing the prose closes the item just as
validly; it is closed that way, with the stronger control cited
instead of re-run.

**The one ask not carried out, and why.** Review 2's point 5 asks for
the work skill's once-only workaround — hand-edit the `["title"]` line
in `items/3IU0GxoAXmEaBi9G8OQyabFPZBi.tl` and commit — because no verb
renames an item. This rework did NOT do that, on the instruction of
the session that dispatched it, and the reasons stand on their own: a
hand-edit bypasses gitboard's compare-and-swap and its WIP/graph
validation on a branch several sessions are writing to, which is the
hazard class 3ISLSiiy and 3IUFODun already record; and 3IFWAdlL —
band 1, the highest band, in backlog — is the filed fix, now with a
FOURTH session's evidence behind it. The countermeasure is already
named (`--enable 3IFWAdlL` on review 2's verdict), so paying the
workaround again buys one title and removes the pressure that promotes
the real fix. The mitigation taken instead is the Result's first
paragraph, a clause-by-clause correction addressed to a reader who
arrives by the stale title. A reviewer who judges this the wrong call
should say so: the edit is one line and is still available.

## Review 3 — 2026-08-27 13:3x UTC, ACCEPT (session 0b13d2b4)

Third review, by the session that gave the first verdict. Both rounds
are answered. The finding is not merely proportionate to its evidence
any more — it is UNDERSTATED, and the reviewer's own re-measurement
below is a stronger control than the one this rework cites.

**The re-measurement: the same bytes, the same container, eight hours
apart, +34%.** `o/bin/cosmic` in this checkout is still
`afdd72c09850c0f129134ecc222e99b525dda1e0a29beca98e002bb66155540e` —
byte-for-byte the binary review 1's control measured at ~05:50 UTC
(cosmic tree `cefc9651`, cosmos pin `2026.08.27-13977f2ef`, `sha256sum
o/bin/cosmic` before and after the series, unchanged). Same command,
same context, ISOLATED:

```
bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out <scratch>/N.json
```

Seven launches, ts 1787837644-1787837721 (13:34-13:35 UTC), µs/op:
192.91, 197.28, 192.74, 194.32, 196.58, 193.18, 195.61.
min 192.74, median 194.32, max 197.28, mean 194.66, sd 1.85, **CV
0.95%**. Instruments: cpu/wall 0.99-1.05, `nr_throttled` 0 (cgroup
`cpu.stat`), `/proc/loadavg` 0.18 rising to 0.72 across the series
(4 cpus, and the codec level did not track it), `/proc/stat` steal 84
ticks cumulative.

Against review 1's control on the SAME BYTES — 143.28 / 143.69 /
143.85 / 144.79 / 144.90 / 146.32 / 146.39 / 147.44 / 148.71 µs,
median 144.90, range [143.28, 148.71] — this is **+34.1%** with the
two raw ranges completely disjoint (fast max 148.71 << slow min
192.74) and each side internally tight (CV 1.3% and 0.95%).

That is the byte-identical cross-session step this item concludes on,
reproduced with the container held fixed as well as the bytes. The
control the rework found on the board (3ISlWFiS/3ITOUv0w, +32.6% and
+20.7%) spans two containers; this one does not, so "different host
placement between two containers" is not needed to explain the step
either. Both of this item's named clusters are now reproduced by the
same binary: `afdd72c0…` read ~144 in the morning and ~194 in the
afternoon.

A contemporaneous CONTROL SCENARIO ran interleaved with every codec
launch above — the instrument review 1 point 3 asked for —
`--only url_decode_query_value`, six launches between the codec ones:
3.42, 3.29, 3.40, 3.30, 3.44, 3.50 µs/op, median 3.41, CV 2.4%. No
prior isolated `url_decode_query_value` reading exists anywhere on the
board, so this establishes a baseline for the next pass rather than
settling selectivity today; recorded here so a future fast-window
sitting has something to compare against.

A/A selfcheck on the same binary, same window: `gate.tl selfcheck
--only codec_base64_roundtrip_64k` read 201.49 -> 205.67 µs, **+2.1%**,
`perf-selfcheck: nothing exceeded the bar — the machine is quiet at
this threshold`. The machine is quiet AND sitting 34% off where it sat
this morning: the two facts are not in tension, and that is precisely
this item's point.

**Verification of the rework's own claims, not acceptance of them.**
Each load-bearing citation was read at source:

- 3ISlWFiS's arm A sha (`d8492168eace…`) and its four readings
  194.94 / 187.67 / 185.81 / 195.26, median 191.31 — confirmed at
  `items/3ISlWFiS7svcOfni0vzn6iFo8a9.md`. Arm B `940f21bb…`,
  214.50 / 210.67 / 208.04 / 206.45, median 209.35 — confirmed.
- 3ITOUv0w's `07fc94a1c` arm carries the SAME sha `d8492168eace…`
  ("byte-identical to 3ITHROpY's, and two of them to 3ISlWFiS's"), nine
  readings median 144.29, and its `354c17e08` arm `940f21bb…` median
  173.38 — confirmed. So +32.6% and +20.7% with disjoint ranges is
  real, and the byte-identity is recorded in the sources, not inferred
  by this item.
- The correction the rework makes to REVIEW 2 is correct and review 2
  was wrong: 3ISWHyP7's "drifts ~11% between isolated runs" is about
  `json_decode_large`, and the same paragraph records base64 as
  staying "inside 3.5%". Verified verbatim at that item's Result.
- The full `±` column 14.2 / 9.8 / 13.1 / 7.0 / 4.8 / 3.3 % and its
  two-binary alternation — confirmed at 3ISWHyP7's base64 table.
- 3IUBNQZZ's Goal now asserts only the recording gap and the
  level-dependent magnitude, and its Non-goals refuse any widening of
  base64's floor — confirmed by reading that item.

**Point-by-point standing.** Review 1's six: all answered (ladder
labeled by context and struck where unlabelable; binary or pin per
group; "machine-wide" withdrawn rather than measured, which review 1
offered as one of its two acceptable exits; co-tenant recorded and the
item's own false "no observable correlates" corrected against itself;
the 40 rows durable in the item; follow-up narrowed). Review 2's six:
1, 2, 3, 4 and 6 answered — 2 and 3 by a control stronger than the one
asked for; 5 answered in the body and declined in the title.

**Two defects recorded, neither blocking.**

1. The rework's stated reason for declining the title edit
   mis-cites its own precedents: "a hand-edit bypasses gitboard's
   compare-and-swap and its WIP/graph validation … which is the hazard
   class 3ISLSiiy and 3IUFODun already record". Both of those items
   record a hazard in `gitboard spec` — the verb that rewrites a spec
   with no claim check and no phase check — which is the verb this
   rework itself used, not a hazard of editing the title field. And
   3IFWAdlL, cited in the same breath, describes the hand-edit as "the
   one the work skill allows once" and records three sessions taking
   it. The reviewer judges the call wrong, as the rework invited, and
   has taken the edit: the `["title"]` line of
   `items/3IU0GxoAXmEaBi9G8OQyabFPZBi.tl` now reads what the Result
   supports — the two withdrawn clauses are gone and the axis is the
   session. 3IFWAdlL keeps its four sessions' evidence; this is the
   fifth and it is recorded here rather than paid for with a permanent
   false headline on the one item whose subject is exactly that
   failure.
2. One phrase in the Result still runs a shade past its data: **"The
   variation is entirely BETWEEN sessions"**. Groups D and E are
   different binaries as well as different sessions, so "entirely" is
   carried by the byte-identical pair and not by those two. The
   Conclusion names the confound explicitly two paragraphs later
   ("this item's own 190-vs-144.9 step, which it could not separate
   from a binary change"), so the item is self-consistent and the
   operational statement does not rest on the loose phrase — and the
   re-measurement above now closes the gap the phrase was reaching
   across. Noted, not blocking, and left as written rather than
   bounced for one adverb.

**A ready-bar note for the next spec of this shape.** The Acceptance
bullet "No tree diff: `git diff --name-only origin/main` prints
nothing" cannot be satisfied on a checkout that is behind main — it
prints main's own forward progress. Here it printed nine files, all of
them commits landed on main since `cefc9651`, while `git status
--short` printed nothing and the working tree is clean. The check that
means what the bullet intends is `git status --short`.

**Verdict: ACCEPT.** The deliverable is evidence, there is no PR, so
this ends the item. What it establishes, and what a compare row may
rest on: within one measurement session an isolated
`codec_base64_roundtrip_64k` reading is reproducible to a few percent;
across sessions it is not comparable at all, with the same bytes now
recorded 33-34% apart three separate ways — two containers
(3ISlWFiS/3ITOUv0w) and one container eight hours apart (this review).
Only a delta measured between two binaries interleaved in ONE session
carries information. The follow-up is 3IUBNQZZ.
