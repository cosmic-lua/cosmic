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

Two brackets run; the fast mode never reappeared; the rework below
re-founds every claim on labeled, durable evidence per the review.

### The durable record (review point 5)

Second bracket, 2026-08-27 04:59-05:38 UTC (ts 1787806772-1787809131),
40 launches of `o/bin/cosmic --make run _perf/run.tl --only
codec_base64_roundtrip_64k --out o/perf/probe-N.json`, one per ~60 s.
Context: ISOLATED (`--only`). Binary: `bin_sha c81de75b787a…` on all
40 runs (cosmic built at main `cb39b65d`, cosmos pin
`2026.08.27-13977f2ef`). Per-run rows (n, ts, wall_us, cpu_us):

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

### What ran beside it (review point 4)

The bracket ran in this container while this session did the gitboard
machinery work: two full `bin/cosmic --make build`s (~05:03, ~05:20),
one full `--make ci` (~05:26-05:31: tree compile plus 26 test files),
and several narrower test runs — cache- and memory-heavy co-tenants,
unrecorded per-run. `/proc/loadavg` was NOT among the instruments
read, so the earlier claim "no in-container observable correlates" is
corrected to: none of the four instruments read (cpu/wall, throttle,
steal, pressure-absence) moved, and system utilization was never
among them. The reviewer's spinner control (three CPU hogs on 3 of 4
cpus, no effect: 143.69/146.32/144.79 µs) rules out a pure CPU hog;
a concurrent compile's cache/memory pressure remains untested.

### The ladder, re-founded (review points 1-3)

Each rung labeled by context and binary; rungs that cannot be
labeled are struck as evidence:

| reading | context | binary (bin_sha / pin) | standing |
|---|---|---|---|
| 95.80 µs | full-suite compare row (PR #1426 gate window) | pre-bump vs post-bump cosmos — TWO binaries | struck: cross-binary AND suite-context |
| 116-133 µs | suite/gate windows ("the capture", no item id, no command recorded) | unretrievable | struck: unretrievable |
| 138-156 µs | isolated `--only` (first bracket, 04:49-04:54) | bin_sha unrecorded (another session's build) | weak: context labeled, binary not |
| 183.6-201.8 µs | isolated `--only` (this bracket) | `c81de75b787a…` / 13977f2ef | sound |
| 143.28-148.71 µs | isolated `--only` (reviewer, 05:49+, nine runs) | `afdd72c0…` / 13977f2ef | sound |

What SURVIVES like-for-like: two sound same-context rungs eleven
minutes apart read 190.2 vs 144.9 µs at medians — a ~24% step —
but on DIFFERENT cosmic builds wrapping the same pinned cosmos, so
machine state and binary build are confounded even there. The
suite-context observation that codec_hex swung with codec_base64
while url_decode and time_format_* held steady stands as recorded,
labeled suite-context; nothing in the isolated brackets measured any
scenario but base64, so "machine-wide" is WITHDRAWN: the drift is
measured for the 64 KB codec path alone (per-scenario selectivity —
steady url/time rows — points at memory/LLC-bound work rather than a
uniform frequency/thermal level).

### Conclusion (revised)

Isolated same-command readings of codec_base64_roundtrip_64k drift
across minutes-scale windows by far more than the same-binary
in-window spread prior work measured (±3.3-4.8%, 3ISlY5Xl/3ISWHyP7),
with none of cpu/wall, throttle, steal, or pressure-absence moving —
and with two confounds this pass could not close: binary build
identity across rungs, and unrecorded co-tenant load. No fast-mode
(<105 µs) isolated reading was ever observed under a recorded
bin_sha; the sub-100 rungs are suite-context or cross-binary. A
third bracket stays banned (step 3); the closable confounds close by
RECORDING (bin_sha per rung, co-tenant, loadavg), which the follow-up
inherits as method, not by more hunting.

### Follow-up (review point 6)

3IUBNQZZ's Goal corrected in the same pass: the four-level
"byte-identical binaries" premise is withdrawn; the surviving premise
is the cross-window drift of same-command isolated readings against
prior same-binary in-window spread, with binary identity a confound
the current gate never records — which is itself the argument for
deriving codec noise floors from same-binary cross-window A/A
history (the A/A selfcheck pair is same-binary by construction) and
for the harness stamping bin_sha into every compare row it prints.
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
