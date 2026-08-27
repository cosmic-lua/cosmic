## Goal

G6 — the defining paths, ratcheted: every table the perf gate prints
names the binaries and the measurement times behind it, so a compare
row can be traced to its subject, and a row quoted out of a report
into a board item carries its own identity with it.

Scope narrowed 2026-08-27 at refinement, after the 14:2x bounce
recorded below. This item now carries ONLY the founded, implementable
half — recording. The level-relative-bar question it used to carry as
"Change part 2" is `3IVDEyar` (backlog, same parent 3HyRcd9F), split
off because its data source does not exist: nothing in the tree
accumulates A/A history to derive a floor from. See `## Non-goals`.

Read the item's TITLE as its opening hypothesis, not as a finding.
"state-split" is NOT established and "derive per-scenario noise
floors from cross-window A/A history" is no longer this item's work;
no gitboard verb renames an item (3IFWAdlL, band 1, backlog).

What 3IU0GxoA established (ACCEPTED after three review rounds; its
sidecar is the evidence base) and all this item rests on:

- **Within one measurement session the scenario is stable.** 40
  isolated launches over 40 minutes on one recorded binary
  (`bin_sha c81de75b787a…`, cosmos `2026.08.27-13977f2ef`) held median
  190.0 µs at CV 2.1%, unimodal, trendless. Every other labeled group
  on record is internally tight at CV 1.2-5.3%.
- **Between sessions the absolute level moves 20-34% with the binary
  BYTE-IDENTICAL.** cosmic `d8492168eace…` read median 191.31 µs in
  one session and 144.29 µs in another, raw ranges disjoint (+32.6%);
  its sibling arm `940f21bb…` read 209.35 and 173.38 the same way
  (+20.7%). 3IU0GxoA's Review 3 reproduced the step inside ONE
  container on ONE binary (`afdd72c09850…`): median 144.90 µs at
  ~05:50Z, 194.32 µs at ~13:34Z, +34.1%, ranges disjoint, each side
  tight (CV 1.3% and 0.95%).
- **Suite-context and isolated readings may never be chained.**
  `skills/optimize/measurement.md` puts them up to 40% apart for the
  SAME binary, and 3IU0GxoA struck every rung it could not label with
  a context on exactly that ground.
- **The gate records nothing about which binary or which window
  produced a row.** `_perf/run.tl` writes `meta.bin_sha` and
  `meta.timestamp` into every results file; `_perf/compare.tl` reads
  `bin_sha` only inside `identity_refusal` and prints neither.

The founded, actionable premise is therefore a RECORDING gap. Two
readings of the same scenario can differ 34% with the bytes held
identical, and the only thing separating them is which window they
were taken in — a fact the printed report does not carry.

## Change

Four files. Stamp each row's two subjects onto the `Delta` inside
`diff`, render them in the row and in a two-line header, and say so
in the measurement chapter. Line counts below are measured at
`origin/main` `54aa87df` on 2026-08-27:
`for f in _perf/compare.tl _perf/perf_types.tl _perf/compare_test.tl;
do git show origin/main:$f | wc -l; done` → 357, 100, 290 (so 143,
400 and 210 lines of headroom under the 500-line cap).

**1. `_perf/perf_types.tl` — four fields on `record Delta`.**

```teal
    base_sha: string
    cur_sha: string
    base_ts: number
    cur_ts: number
```

Doc them in the record's existing `---` block: the identity of the
two results files this row was diffed from — the baseline side's and
the current side's `meta.bin_sha` and `meta.timestamp`. Absent when
the results file recorded none. `record Meta` and `record Measurement`
do not change, so the on-disk JSON does not change.

**2. `_perf/compare.tl` — stamp in `diff`, render in `format_delta`
and `format`.**

- Add `local time = require("cosmic.time")` beside the existing
  requires.
- In `diff`, read the pair ONCE before the loops and assign all four
  onto every `pt.Delta` it builds — the current-side loop and the
  trailing `missing` loop both:

  ```teal
  local bmeta = base.meta
  local cmeta = cur.meta
  local base_sha = bmeta and bmeta.bin_sha
  local cur_sha = cmeta and cmeta.bin_sha
  local base_ts = bmeta and bmeta.timestamp
  local cur_ts = cmeta and cmeta.timestamp
  ```

  (`identity_refusal` in the same file already guards `meta` this
  way.) Every row of one `diff` therefore carries the SAME pair,
  which is what lets `format` read its header off row 1.
- Add a private `short(sha: string): string` — `string.sub(sha, 1, 8)`,
  or `"--------"` (eight dashes) when the sha is nil. Eight dashes
  rather than a word like `unknown`, for the reason `collect_meta`
  already gives in `_perf/run.tl`: a file that cannot name its subject
  is left visibly incomplete rather than filled in with something that
  reads as an answer.
- Add a private `format_ts(ts: number): string` — `"unrecorded"` when
  the timestamp is nil or `math.tointeger` returns nil for it,
  otherwise `time.format_iso8601`'s string, falling back to
  `"unrecorded"` when that returns nil.
- `format_delta` keeps its signature and gains ONE fixed-width field
  between the noise column and the verdict:

  ```teal
  return string.format("%-28s %12s -> %12s  %8s  (noise %7s)  %8s/%-8s  %s",
    d.name, base_str, cur_str, delta_str, noise_str,
    short(d.base_sha), short(d.cur_sha), d.verdict)
  ```

- `format` keeps its signature `(deltas: {pt.Delta}): string` and
  PREPENDS two header lines, read off `deltas[1]`:

  ```
  perf-subjects: base <64-hex or "unrecorded"> measured <ISO-8601 UTC or "unrecorded">
  perf-subjects: cur  <64-hex or "unrecorded"> measured <ISO-8601 UTC or "unrecorded">
  ```

  `base`/`cur ` as a `%-4s` so the two hashes align. When `deltas` is
  empty there is no pair to name and no header is printed.

The shape decisions above are SETTLED here; the previous revision of
this spec reserved them to plan and that is what bounced it. Do not
re-open them at implementation:

- **per-row, not header-only** — rows get quoted one at a time into
  board items (3IU0GxoA's Result and this item's own bounce below both
  do it) and a header is left behind by the quote. The short pair
  travels with the row.
- **stamped in `diff`, not passed into `format`** — `compare.format`
  has five call sites (`grep -c "compare\.format(" _perf/gate.tl
  _perf/run.tl` at origin/main → `_perf/gate.tl:4`, `_perf/run.tl:1`)
  and `gate.tl` prints four different tables in one gated run. A new
  parameter is four chances to forget; a field populated by `diff`
  cannot be omitted by a print site, and no call site has to change.
- **both sides, always** — the hazard is a PAIR. Same sha with
  different times is the cross-session chain 3IU0GxoA established;
  different shas is the cross-binary one `identity_refusal` already
  refuses. A row that shows only one side answers neither.
- **8 hex in the row, 64 in the header** — 8 hex separates every
  binary in this board's record and keeps a row near 121 columns; the
  header carries the full hash a reader can `sha256sum` against.
- **times in the header only** — four time fields per row would push a
  row past 150 columns to repeat a fact that is identical on every row
  of one table.

**3. `_perf/compare_test.tl` — two tests.**

**This file is in RUNNER MODE at origin/main**: `grep -c "^test_"
_perf/compare_test.tl` is `0` — every `test_*` is defined and none is
self-called. AGENTS.md still says "test files call each test where they
define it"; obeying that here makes the file MIXED, which is a lint
FAILURE by D29 (`docs/decisions/d29-tests-run-because-defined.md`:
"every `test_*` self-called is legacy mode … none self-called is runner
mode … MIXED is a lint failure"). Define the two functions above the
closing `print("OK compare_test")` and do NOT call them.

- `test_diff_stamps_both_binaries` — `diff` two `Results` whose `meta`
  carry distinct `bin_sha` and `timestamp`, over a scenario set that
  includes one name present in the BASELINE only (so a `missing` row
  is produced). Assert every delta, the `missing` row included, carries
  `base_sha`/`cur_sha`/`base_ts`/`cur_ts` equal to the two `meta`s.
- `test_format_prints_subjects_and_row_shas` — `compare.format` over
  those deltas contains `perf-subjects: base <full base sha>`,
  `perf-subjects: cur  <full cur sha>`, and a row containing
  `<base 8 hex>/<cur 8 hex>`. Over deltas built from the file's
  existing `results()` helper (whose `meta` is `{}`) it contains
  `--------/--------` and `unrecorded`.

Add a SECOND helper for the identity-carrying `Results` rather than
changing `results()`, so the file's existing tests keep exercising the
no-identity path.

**4. `skills/optimize/measurement.md` — one sentence** (134 lines at
origin/main). In the "know which binary you measured" bullet, directly
after "every results file records `meta.bin_sha`, and the compare gate
refuses a compare whose two sides hashed the same binary", add one
sentence: every table the gate prints opens with two `perf-subjects:`
lines carrying each side's full sha and measurement time, and every row
carries the two 8-hex prefixes, so a row quoted out of a report still
names its subjects. No other edit to that file.

## Non-goals

- **No threshold moves, in either direction.**
  `DEFAULT_THRESHOLD_PCT = 10.0` and `TRIAGE_K = 2.0` in
  `_perf/compare.tl` are the ONLY committed thresholds in `_perf`
  (`git grep -c "threshold\|noise_floor" origin/main -- _perf/bench/`
  returns nothing) and both keep their values. This is 3IU0GxoA's
  "What this does NOT license", and it binds here: the release lane
  measures baseline and candidate in the SAME job on the SAME runner,
  which is the interleaved shape the cross-session effect cannot
  reach, and 3ISlY5Xl held a release at +21.0% on that arithmetic.
- **No A/A history store and no level-relative bar.** That is
  `3IVDEyar` (backlog, parent 3HyRcd9F). Nothing here accumulates
  selfcheck results, writes a history file, adds a `noise_floor_pct`
  to a scenario module, or normalises a delta by the session's level.
  The reason this item may not reach for it: `_perf/gate.tl`'s
  `selfcheck` measures into the two paths the CALLER names, compares,
  and returns — nothing accumulates — and `o/perf/*.json` is never
  committed, so there is no cross-window A/A history in the tree to
  derive anything from.
- **No change to classification.** `diff`, `triage`, `triage_many`,
  `loudest_control` keep their logic: no verdict added or removed, and
  `noise_pct` stays `max(threshold, base spread, cur spread)`.
- **No change to `identity_refusal`** — its two rules and its refusal
  texts stay byte-identical. This slice makes identity VISIBLE;
  refusing on it is already built and is not being re-litigated.
- **No change to any verdict or summary line.** `perf-compare: PASS`,
  `perf-compare: FAIL`, `perf-selfcheck: …`, `perf-baseline: SKIP`
  (`.github/workflows/release.yml` greps that one) and the
  `N scenarios: …` count line are byte-identical after this change.
  The `perf-subjects:` lines are ADDED above the rows.
- **No change to the results JSON format.** `record Meta` and
  `record Measurement` are frozen here; a results file written before
  this change must still compare cleanly after it — which is what the
  release lane does when the PREVIOUS release's `perf.json` meets the
  new binary.
- **Do not touch `_perf/gate.tl` or `_perf/run.tl`.** Both keep their
  existing `compare.format(deltas)` calls verbatim; that no call site
  changes is the point of stamping inside `diff`.
- **Not a fix for `3IRRr3VN`** (selfcheck's two path arguments are both
  written and the call site cannot tell read from write). Use two fresh
  paths in the acceptance run and leave that item alone.
- No new flags, no new scenario, no `check()` change, no benchmark
  added or removed.
- No performance claim is made or gated by this slice. Do not run the
  compare gate for a verdict on the tree, and do not quote a timing
  from this work as evidence anywhere.

## Acceptance

Run from the repo root. Commands 4-6 are the bounds this item fixes.

1. `bin/cosmic --make ci` ends `ci: PASS`.
2. `bin/cosmic --make test _perf/compare_test.tl _perf/gate_test.tl
   _perf/run_test.tl` passes, including the two new tests named in
   `## Change`.
3. Identity in a real report, end to end:

   ```
   bin/cosmic --make build
   sha256sum o/bin/cosmic
   bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa-a.json o/perf/aa-b.json \
     --only codec_base64_roundtrip_64k --samples 3 --min-secs 0.05
   ```

   The report must open with two `perf-subjects:` lines whose 64-hex
   shas BOTH equal `sha256sum o/bin/cosmic`'s output and whose
   `measured` stamps are two ISO-8601 UTC times seconds apart; the
   `codec_base64_roundtrip_64k` row must carry
   `<first 8 of that sha>/<first 8 of that sha>` between the noise
   column and the verdict; and the run must still end with a
   `perf-selfcheck: …` line and exit 0. The scouting
   `--samples`/`--min-secs` are deliberate — this checks the report's
   SHAPE, never a timing.

   What the same command prints TODAY, measured 2026-08-27 14:32 UTC
   against binary `145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`
   (`sha256sum o/bin/cosmic`), invoked as
   `o/bin/cosmic _perf/gate.tl selfcheck <scratch>/aa-a.json
   <scratch>/aa-b.json --only codec_base64_roundtrip_64k --samples 3
   --min-secs 0.05`:

   ```
   codec_base64_roundtrip_64k      326.71 µs ->    199.51 µs    -38.9%  (noise  ±15.8%)  faster
   1 scenarios: 0 regression, 1 faster, 0 ok, 0 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0 malformed
   perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
   ```

   No header, no identity on the row — the gap this closes. (The two
   results files it wrote do carry it:
   `grep -o '"bin_sha":"[a-f0-9]*"' <scratch>/aa-a.json` printed that
   same 64-hex, and `grep -o '"timestamp":[0-9]*'` printed
   `1787841139` and `1787841140`.)
4. `grep -c "DEFAULT_THRESHOLD_PCT = 10.0\|TRIAGE_K = 2.0"
   _perf/compare.tl` prints `2` — unchanged from today (same command
   at origin/main `54aa87df` prints `2`).
5. `wc -l _perf/compare.tl` is at most `420` and
   `wc -l _perf/perf_types.tl` is at most `120` (357 and 100 today);
   both stay under the 500-line cap.
6. `git diff origin/main -- _perf/gate.tl _perf/run.tl` prints
   nothing — neither file is touched.

If the coverage ratchet complains in step 1, run exactly the regen
command its failure message prints
(`bin/cosmic --make coverage --baseline`) and commit the result. That
is the only sanctioned response; no gate is weakened any other way.
The two tests in `## Change` are written to cover both the
identity-present and the identity-absent branches of `short` and
`format_ts`, so a dip should not arise.

## Enablement

`none needed`. `blocked_by` is empty; nothing has to land first.
Everything this slice touches exists and is gated today:

- **The mixed-mode trap is already caught by core.** D29's
  call-after-define lint fails a file where some `test_*` are
  self-called and some are not, and `--make ci`'s lint stage runs it
  (acceptance step 1). The spec names the trap; the gate enforces it.
- **`cosmic.time.format_iso8601` exists in the pinned release
  binary**, which is the older-embedded-cosmic path `release.yml`
  exercises when the PREVIOUS release binary runs this tree's
  `_perf/run.tl`. Verified 2026-08-27 against `bin/cosmic.pin`'s
  `145057b9fe90…`:
  `o/bin/cosmic -e 'local t=require("cosmic.time")
  print(t.format_iso8601(1787841139))'` → `2026-08-27T14:32:19Z`.
- **`meta.bin_sha` and `meta.timestamp` are already written** by
  `_perf/run.tl`'s `collect_meta` — confirmed in a live results file
  under `## Acceptance` step 3.
- **The gate machinery this reports on already exists** (#1432).

Related, not a blocker: `3IVDEyar` holds the level-relative-bar
question split out of this item, and stays in the backlog until
someone is ready to answer it from recorded data.

## Bounce — 2026-08-27 14:2x UTC, returned to plan (session 0b13d2b4)

Pulled, re-measured, and returned unbuilt: the Change defers its own
shape to plan twice and the Acceptance is unwritten, so there is
nothing here that can be implemented from the spec alone. The
re-measurement below is recorded so the next refine starts from
pull-time numbers.

**Re-measured at pull.** Binary `145057b9fe90…` (`sha256sum
o/bin/cosmic`), cosmic main `267c2a4d`, built in this container.
Context ISOLATED, five launches 14:23-14:24 UTC:

```
o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out <scratch>/probe-N.json
```

187.50, 189.49, 193.96, 211.57, 221.10 µs/op — min 187.50, median
193.96, max 221.10, mean 200.72, sd 14.9, CV 7.4%. This session sits
on the **~190 level**, within 0.2% of 3IU0GxoA Review 3's afternoon
median of 194.32 µs on a different binary and within 2% of that
item's 40-run bracket median of 190.0 µs. So the Goal's shape holds
at pull: a session lands on one of the recorded levels and this one
landed on the slow one. Its dispersion is looser than the 40-run
bracket's CV 2.1% (the last two launches ran hot, `±13.0%` and
`±19.3%` within-run), which is a detail, not a shape change.

**The recording gap reproduces verbatim.** A/A selfcheck, same binary,
same window, `o/bin/cosmic --make run _perf/gate.tl selfcheck
<scratch>/aa-a.json <scratch>/aa-b.json --only
codec_base64_roundtrip_64k` printed:

```
codec_base64_roundtrip_64k      201.49 µs ->    214.04 µs     +6.2%  (noise  ±52.4%)  ok
perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
```

Name, base, current, delta, noise, verdict — and no binary identity on
either side, which is the Goal's fourth bullet unchanged. Part 1 of
the Change is still real and still worth building.

**Why it bounced, three gaps, none of them mine to settle mid-slice.**

1. **`## Acceptance` is unwritten** — it reads "To be written at
   refinement, with the derivation command and its measured output
   quoted." The acceptance commands are the definition of done; with
   none, the slice has no closing condition and the reviewer has no
   evidence to demand.
2. **Change part 1 defers its own shape**: "the shape and the files to
   touch are to be settled at plan", and plan did not settle them.
   Today `_perf/compare.tl`'s `format_delta`/`format` print exactly the
   six fields above, and `meta.bin_sha` is read only by
   `identity_refusal`. Whether the identity lands as a report header,
   a per-row column, one side or both, short or full hex — and whether
   `format_delta`'s signature has to grow to carry it — is a design
   decision the spec reserves to plan, not a detail an implementer
   fills in.
3. **Change part 2's data source does not exist.** It asks for a floor
   derived "from the selfcheck files the gate already writes". The
   gate writes the two results files the CALLER names and persists no
   history: `_perf/gate.tl`'s `selfcheck` takes `A.json B.json`,
   measures into both, compares, and returns — nothing accumulates,
   and `o/perf/*.json` is never committed (AGENTS.md). There is no
   accumulated cross-window A/A history anywhere in the tree to derive
   a per-scenario floor from, so answering "does a history-derived
   floor improve on `spread_pct`" first requires DECIDING to build a
   history store and where it lives. That is the shape question the
   spec says plan must answer, and it is unanswered.

No tree diff and no PR: the branch cut for this slice
(`claude/3IUBNQZZ-noise-floors`, off `267c2a4d`) carries no commits.

## Refine — 2026-08-27 14:4x UTC (session 0b13d2b4)

All three bounce gaps answered, by splitting rather than by widening.

- Gap 3 settled by the SPLIT: part 2 left this item entirely for
  `3IVDEyar`, which the bouncing session had already filed under the
  same parent one second before the bounce. This item's `## Non-goals`
  now walls it off and says why (no history store exists, and building
  one is a shape decision this item's own Non-goals forbade it from
  taking). `3IVDEyar`'s "Relation to 3IUBNQZZ" paragraph already
  asserts this division; it is now true on both sides.
- Gap 2 settled in `## Change`: per-row plus a two-line header,
  stamped by `diff` onto `Delta` so no call site changes, 8 hex in
  the row and 64 in the header, both sides, times in the header only —
  each with the reason it beat its alternative.
- Gap 1 settled in `## Acceptance`: six runnable commands with stated
  expected output, including the two bounds the previous revision
  fixed (a row printing a binary identity for both sides; no committed
  threshold ending larger than it starts) and a `wc -l` cap on the two
  files that grow.

Tree facts re-measured at `origin/main` `54aa87df` during this pass —
line counts, `compare.format` call sites, the two threshold constants,
`_perf/compare_test.tl`'s runner mode, and the live "before" report —
each with its command quoted where it is asserted. One fact moved
since the bounce and is worth flagging to whoever builds this: the
bounce measured `267c2a4d`, and `54aa87df` (PR #1458, "migrate the
internal trees to runner mode, batch 1/7") has since converted every
`_perf/*_test.tl` to runner mode. That is why `## Change` part 3 spends
a paragraph on it.
