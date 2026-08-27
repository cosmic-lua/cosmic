## Goal

G6 — the defining paths, ratcheted: establish, from recorded evidence,
how far a single isolated reading of `codec_base64_roundtrip_64k` can
be trusted — within one window and binary, and across windows and
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

**Read this first if you arrived by the title.** The title still says
"swings 25-30% across minutes machine-wide on both runtimes". This
item establishes none of that, and the title cannot be corrected: no
gitboard verb renames an item (3IFWAdlL, backlog, band 1). What this
item DOES establish, from 40 launches over 40 minutes on ONE recorded
binary, is the opposite: isolated `codec_base64_roundtrip_64k`
readings held to a coefficient of variation of 2.1% around 190 µs,
with no bimodality and no trend. WITHDRAWN, in order: any
minutes-scale swing within one binary (the 40 rows below refute it);
"machine-wide" (neither bracket measured any scenario but base64);
"both runtimes" (nothing here measured two runtimes — its only
support was two readings this pass struck as cross-binary). What
survives is a narrower and still useful negative result, stated in
the Conclusion below: this scenario reproduces tightly WITHIN a
window and binary and is not comparable ACROSS them, and every level
step in the whole recorded history coincides with a change of binary.

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

**What those 40 rows say, and it is the pass's most solid number.**
min 183.6, median 189.95 (the two middle values are 189.7 and 190.2),
max 201.8, mean 190.44, sample sd 4.03 (population sd 3.98),
**CV 2.1%**, range -3.3% / +6.2% about the median, max/min 1.099.
Split in half by time, the first 20 launches median 189.55 and the
second 20 median 190.55 — a 0.5% difference, so there is no drift
across the 40 minutes either, not merely no bimodality. Forty
launches, forty minutes, one recorded `bin_sha`, one context, one
tight unimodal band. This is the only same-binary same-context
cross-window dataset this item owns, and it argues AGAINST
minutes-scale instability within a window rather than for it.

One caution on comparing that CV against the "±3.3-4.8%" figure the
earlier Conclusion cited: they are not the same statistic. CV 2.1% is
a standard deviation across 40 separate launches; the harness's `±`
is a within-run spread over the 5 samples of ONE invocation. The
honest statement is the standalone one — 40 launches held to CV 2.1%
— not a ratio between two different measures.

**Every isolated `--only codec_base64_roundtrip_64k` reading on
record, grouped by the binary that produced it.** Assembled from this
item, 3ISWHyP7's Result, and review 1's control set. Each group is
one binary; the last column is that group's own internal spread.

| # | date | binary / pin | readings (µs) | internal spread |
|---|---|---|---|---|
| A | 08-26 | main `ec794d44`, pin `2026.08.26-fe7c36c4c` | 216.60, 209.58 | -3.2% (A/A pair) |
| B | 08-26 | worktree `5ef13f40`, pin `2026.08.21-07fc94a1c` | 191.73, 196.18, 193.46 | CV 1.2% |
| C | 08-26 | worktree `5ef13f40`, pin `2026.08.24-354c17e08` | 227.05, 206.34, 208.58 | CV 5.3% |
| D | 08-27 | `c81de75b787a…`, main `cb39b65d`, pin `13977f2ef` | 40 launches, 183.6-201.8, median 190.0 | CV 2.1% |
| E | 08-27 | `afdd72c09850…`, pin `13977f2ef` (review 1's control) | 143.28-148.71, median 144.9, 9 launches | CV 1.3% |
| F | 08-27 | first bracket, `bin_sha` UNRECORDED | 138-156 | not labeled |

The shape that falls out of the table is the finding. Every group
whose binary is recorded is internally tight: CV 1.2% to 5.3% across
groups of 2 to 40 launches, none of them showing anything like a
25-30% swing inside itself. The levels BETWEEN groups span 144.9 to
227 µs — a factor of 1.57 — and every step between levels coincides
with a change of binary. Not one level change in the whole recorded
history happens with the binary held still.

**The polarity question: which reading is the anomaly.** The earlier
Conclusion treated 144.9 µs as the baseline and the ~190 band as
drift away from it. The record supports the opposite framing at least
as well, and probably better. Group B — three isolated readings on
one binary, a day earlier and on a different cosmos pin — reads
median 193.46 µs, within 1.8% of group D's 190.0 median. So the ~190
level has now been read on two days, two cosmos pins and two distinct
cosmic builds, 40 launches in one of those groups. The 144.9 µs level
(group E) has been read once, on one binary, in nine launches. Groups
A and C sit at 210-227. Against that record, group E is the outlier
and ~190-210 is where this scenario usually lives; "a slow window
lasting forty minutes" is the less parsimonious reading, because the
slow level reproduced a day apart on unrelated builds. This does not
prove group E's build is intrinsically faster — nothing here
separates build identity from machine state — but the earlier
framing's choice of baseline was not the neutral one and is corrected
here.

**A correction to review 2, point 3.** Review 2 quoted 3ISWHyP7 as
concluding "the scenario drifts ~11% between isolated runs" of
base64. That sentence in 3ISWHyP7 is about `json_decode_large`, not
base64. What 3ISWHyP7 actually recorded for base64, in the same
paragraph, is: "`--only codec_base64_roundtrip_64k`: 216.60 -> 209.58
µs -3.2%, ±3.0% ... ACROSS calls `json_decode_large` drifts 1.14 →
1.27 ms, about 11% ... while base64 stays inside 3.5%." So the prior
record characterises base64 as the STABLE one of the two scenarios
across isolated calls. That cuts the same way as the 40-run bracket
and against this item's headline, and it is recorded here rather than
quietly dropped.

**The comparator, corrected (review 2 point 4).** The earlier
Conclusion cited "±3.3-4.8%" as the prior same-binary in-window
spread. That is the two tightest values of six. 3ISWHyP7's full `±`
column across its six isolated rounds is **14.2 / 9.8 / 13.1 / 7.0 /
4.8 / 3.3 %**, and those six rounds alternate between TWO binaries
(three per side), so the column is not a same-binary series either.
The `±` also falls monotonically from round 1 to round 6, which looks
like machine warm-up across the sitting rather than a property of
either binary. 3ISlY5Xl quoted the tightest pair deliberately and
correctly: it was building a worst-case argument, in which using the
SMALLEST plausible noise figure is the conservative choice
(`21.0 > max(10.0, 2 x 4.8 = 9.6)` holds a fortiori for any larger
figure). Re-used here as *the* prior spread, the same pair understates
by about 3x, so "far beyond the same-binary in-window spread prior
work measured" is withdrawn as a load-bearing phrase from this
Conclusion and from 3IUBNQZZ's Goal.

**What ran beside the bracket (review 1 point 4).** The bracket ran
in this container while the building session did gitboard machinery
work: two full `bin/cosmic --make build`s (~05:03, ~05:20), one full
`--make ci` (~05:26-05:31: tree compile plus 26 test files), and
several narrower test runs — cache- and memory-heavy co-tenants,
unrecorded per-run. `/proc/loadavg` was NOT among the instruments
read, so this item's earlier claim "no in-container observable
correlates" was false as written and is corrected to: none of the
four instruments actually read (cpu/wall ratio, cgroup throttle,
steal, pressure-absence) moved, and system utilization was never
among them. Review 1's spinner control — three CPU hogs on 3 of 4
cpus during three of its nine launches, readings 143.69 / 146.32 /
144.79 µs — rules out a pure CPU hog as the mechanism; a concurrent
compile's cache and memory pressure remains untested. Note that the
co-tenancy runs the WRONG way for the drift story: the 40-run
bracket, the one with heavy co-tenants, is the tight dataset.

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
recorded `bin_sha` was ever observed, in either bracket.

**Conclusion.** Stated at the width the recorded data carries. Over 40
minutes and 40 isolated launches on one recorded binary
(`c81de75b787a…`, cosmos `13977f2ef`), `codec_base64_roundtrip_64k`
held a median of 190.0 µs at CV 2.1%, unimodal, with no drift between
its first and second halves — the scenario is STABLE within a window
and a binary, and this item's founding hypothesis of a minutes-scale
bimodal machine mode is not supported by anything it measured. Across
the six recorded isolated datasets the LEVEL ranges from 144.9 to 227
µs with the codec source byte-identical throughout, and every level
step coincides with a change of binary; the largest single step, 190.0
to 144.9 µs (~24%) eleven minutes apart, is between two different
cosmic builds over the same pinned cosmos, so machine state and build
identity moved together and this pass separated neither. None of
cpu/wall ratio, cgroup throttle, steal, or pressure-absence moved
anywhere in the record, and system utilization was never read. The
operational statement, and the only one a compare row should rest on:
**an isolated reading of this scenario is reproducible to a few
percent within its own window and binary, and is not comparable across
binaries or measurement sessions, where differences up to 1.5x have
been recorded with no change to the codec.** The earlier framing of
144.9 µs as the baseline is corrected: it is the outlier of the
record, not its floor.

**What this does NOT license, stated explicitly.** It is not a reason
to widen `codec_base64_roundtrip_64k`'s noise floor in the perf gate,
and this item asks for no such change (`## Non-goals`). 3ISlY5Xl used
this scenario's tightness to keep a release blocked at +21.0% via
`21.0 > max(10.0, 2 x 4.8)`, and everything measured here makes that
scenario look MORE stable within a window, not less — the 40-run
bracket is tighter than the figure that arithmetic used. The
cross-binary spread recorded above is not a noise budget either,
because no two of those datasets were ever measured back to back:
they are unseparated build-identity and machine-state differences,
which is a reason to RECORD binary identity per compare row and to
run the interleaved A/B control, not a reason to raise a bar. Any
future proposal to move that floor needs same-binary cross-window A/A
history, which this item does not have and did not collect.

**The one open confound, and the instrument that closes it.** Both
recorded binaries are identified (`c81de75b787a…` at main `cb39b65d`,
`afdd72c09850…`, same cosmos pin `13977f2ef`). Rebuilding both and
running `--only codec_base64_roundtrip_64k` back to back, twice per
side, is `measurement.md`'s instrument of record and would separate
build identity from machine state outright. It is NOT run here: it is
a control, not a third fast-mode bracket (step 3's ban stands), but
this rework was scoped to narrowing claims against evidence already
recorded, and the container is shared and noisy, so a fresh
single-window reading taken now would be exactly the kind of number
this item exists to distrust. It is recorded as the next instrument
for whoever wants the stronger result, and 3IUBNQZZ carries it.

**Follow-up: 3IUBNQZZ, under G6.** Its Goal was rewritten in the same
pass as this rework. What it may assert is only what survives above:
the perf gate derives a scenario's noise floor from a single window's
spread and never records which binary produced a row, while the one
cross-window same-binary dataset that exists (this bracket) shows the
scenario is tight within a binary and every observed level step sits
on a binary change the gate cannot see. So the actionable half is
RECORDING — `meta.bin_sha` stamped into every compare row the harness
prints — justified by the confound existing. The noise-floor
derivation from cross-window A/A history stays a hypothesis to be
tested at plan against accumulated selfcheck history, not a finding,
and explicitly not a warrant to widen base64's bar.

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

## Rework 2 — 2026-08-27 13:1x UTC (session 05f7c552)

Claim taken over from `3f616956` after it went stale 6h, with
`move 3IU0GxoA do --claim 05f7c552-… --force --why …` — the takeover
`next` itself printed. No new measurement was taken and none was
needed: review 2 recorded that every change it asked for is a
restatement of readings already on the board, and step 3's ban on a
third bracket stands untouched.

Disposition of review 1's six points, all of which the first rework
answered and this one keeps:

1. **Ladder mixes contexts** — the labeled ladder stands, with the
   `measurement.md` 40%-in-suite rule quoted as the reason the two
   sub-100 rungs may never chain to the isolated ones.
2. **bin_sha per rung** — stands; the new by-binary table carries
   `bin_sha` or pin for every group and marks group F unlabeled.
3. **"machine-wide" not measured** — withdrawn, and now withdrawn in
   the Result's FIRST paragraph rather than midway through.
4. **Co-tenant unrecorded** — stands, plus the observation that the
   co-tenancy runs against the drift story: the heavily co-tenanted
   bracket is the tight dataset.
5. **Nothing durable survives** — the 40 per-run rows stay in the
   item verbatim.
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
   Result states the CV standalone instead of as a ratio.
2. **The 24% step coincides with a binary change** — the Conclusion
   now leads with the within-binary stability and states the step as
   an unseparated build-identity/machine-state confound.
3. **Polarity unexamined** — done, and founded rather than asserted:
   3ISWHyP7's group B (three isolated readings, one binary) reads
   median 193.46 µs, within 1.8% of this bracket's 190.0, so the ~190
   level reproduces across two days, two cosmos pins and two builds
   while 144.9 has been read once. WITH ONE CORRECTION TO REVIEW 2:
   its quoted "drifts ~11% between isolated runs" is 3ISWHyP7's
   finding about `json_decode_large`, not base64 — the same paragraph
   records base64 as staying "inside 3.5%" across isolated calls.
   The correction strengthens the narrowing rather than resisting it.
4. **The ±3.3-4.8% comparator** — done: the full column 14.2 / 9.8 /
   13.1 / 7.0 / 4.8 / 3.3 % is quoted, with the note that the six
   rounds straddle two binaries and that 3ISlY5Xl's use of the
   tightest pair was correct for a worst-case argument. The phrase
   "far beyond the same-binary in-window spread prior work measured"
   is withdrawn from this item and from 3IUBNQZZ.
5. **"both runtimes"** — WITHDRAWN in the body, in the Result's first
   paragraph, alongside "machine-wide". The TITLE is not edited: see
   the next paragraph.
6. **3IUBNQZZ still carries the un-narrowed premise** — rewritten;
   the cross-binary pair no longer carries the drift claim, and the
   Goal now says in terms that it is not a warrant to widen base64's
   floor.

**The one ask not carried out, and why.** Review 2's point 5 asks for
the work skill's once-only workaround — hand-edit the `["title"]`
line in `items/3IU0GxoAXmEaBi9G8OQyabFPZBi.tl` and commit — because
no verb renames an item. This rework did NOT do that, on the
instruction of the session that dispatched it, and the reasons stand
on their own: a hand-edit bypasses gitboard's compare-and-swap and
its WIP/graph validation on a branch three sessions are writing to,
which is the hazard class 3ISLSiiy and 3IUFODun already record; and
3IFWAdlL — band 1, the highest band, in backlog — is the filed fix,
now with a FOURTH session's evidence behind it. The countermeasure is
already named (`--enable 3IFWAdlL` on review 2's verdict), so paying
the workaround again buys one title and removes the pressure that
promotes the real fix. The mitigation taken instead is that the
Result's first paragraph is a correction addressed to a reader who
arrived by the stale title, naming each withdrawn clause. A reviewer
who judges this the wrong call should say so: the edit is one line
and is still available.

