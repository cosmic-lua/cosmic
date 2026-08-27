## Goal

G6 — the defining paths, ratcheted: every table the perf gate prints
names the binary and the measurement time behind each of its two
sides, so no reader can chain a row from one session onto a row from
another.

Read the TITLE as this item's opening hypothesis, not as a finding.
"State-split" is not established, deriving per-scenario noise floors
from cross-window A/A history is not what this slice builds, and no
verb renames an item (3IFWAdlL, band 1, backlog). Refined
2026-08-27 14:4x UTC against the bounce recorded at the foot of this
sidecar, which named three gaps; this refinement settles all three, and
re-measured at `origin/main` `54aa87df` after runner-mode batch 1
(#1458) landed mid-refine.

What 3IU0GxoA's Result establishes, and all this item may assume:

- **Within one measurement session the scenario is stable.** 40
  isolated launches over 40 minutes on one recorded binary
  (`bin_sha c81de75b787a…`, cosmos `2026.08.27-13977f2ef`) held median
  190.0 µs at **CV 2.1%**, unimodal, with no trend between the first
  and second halves. Every other labeled group on record is internally
  tight at CV 1.2-5.3%.
- **Between sessions the absolute level moves 20-33% with the binary
  BYTE-IDENTICAL.** 3ISlWFiS and 3ITOUv0w each measured cosmic
  `d8492168eace…` (`sha256sum`-verified in both, and a third time by
  3ITHROpY) with the same isolated command: median 191.31 µs in one
  session, 144.29 µs in the other, raw ranges disjoint (+32.6%). Its
  sibling arm `940f21bb…` read 209.35 and 173.38 the same way
  (+20.7%). The two ratios differ, so it is not a uniform frequency
  scaling, and nothing observable inside the container moved.
- **A real regression's measured magnitude depends on which level the
  session landed on.** The same code delta read +9.44% interleaved at
  the ~191 level (3ISlWFiS) and +20.16% interleaved at the ~144 level
  (3ITOUv0w) — both REPRODUCED, both correctly interleaved within one
  session. That consequence is NOT this slice's to act on; it is
  3IVDirCO, filed under G6 and left in the backlog deliberately.
- **The gate records nothing about which binary produced a row.** The
  harness writes `meta.bin_sha` and `meta.timestamp` per results file
  and stamps neither into any printed table, so two tables from
  different binaries — or from different sessions — chain silently.

The founded, actionable premise is a RECORDING gap. That is all this
slice builds.

## Change

Label every comparison table the perf harness prints with the identity
and the measurement time of BOTH sides. Files, with headroom measured
2026-08-27 at `origin/main` `54aa87df` by
`git show origin/main:<path> | wc -l`:

- `_perf/compare.tl` — 357 lines, 143 of headroom under the 500-line
  cap.
- `_perf/gate.tl` — 406 lines, 94 of headroom.
- `_perf/run.tl` — 405 lines, 95 of headroom.
- `_perf/compare_test.tl` — 290 lines, 210 of headroom.
- `skills/optimize/measurement.md` — 134 lines, 366 of headroom.
- `_perf/gate_test.tl` — 479 lines, 21 of headroom, and **not touched
  at all**. The change is designed so it needs no edit there: that file
  calls `compare.load_results` and never `compare.format`
  (`git show origin/main:_perf/gate_test.tl | grep -c 'compare\.format('`
  is 0).

**In `_perf/compare.tl`, three edits.**

1. Widen `RESULTS_SPEC`'s `meta` record to name `bin` and `timestamp`
   beside the `bin_sha` it already names, each
   `shape.optional(...)` — `bin = shape.optional(shape.string)`,
   `timestamp = shape.optional(shape.number)`. `shape.into` DROPS keys
   a Spec does not name, so without this edit both fields read back nil
   from every file on disk and the new line silently prints
   `unrecorded` forever. Extend the record's existing doc comment,
   which today explains why the other fields are left unnamed.

2. Add `format_gap(gap_secs: number): string`, exported. Signed,
   integer, three scales: `< 60` → `+42s`; `< 3600` → `+39m`; else
   `+8h24m`. Take the sign with an explicit `if g < 0` branch and the
   magnitude by negation rather than `math.abs`, so nothing needs an
   `as` cast to stay an `integer`; `math.floor` yields an integer and
   `//` between integers stays one.

3. Add `provenance(a_path: string, a_res: pt.Results, b_path: string,
   b_res: pt.Results): string`, exported, returning exactly two
   `\n`-joined lines:

   ```
   perf: base o/perf/prev/perf.json  bin o/perf/prev/cosmic-lua  sha d8492168eace  measured 2026-08-26T21:14:07Z
   perf: cur  o/perf/perf.json  bin o/bin/cosmic  sha c81de75b787a  measured 2026-08-27T05:38:51Z  gap +8h24m
   ```

   `sha` is `string.sub(bin_sha, 1, 12)`, the same 12 characters
   `identity_refusal` already quotes. `measured` is
   `time.format_iso8601(math.floor(meta.timestamp))` — a fallible call,
   so take `or "unrecorded"` and never `assert` it; the field is typed
   `number` in `pt.Meta` and `format_iso8601` takes an `integer`, hence
   the `math.floor`. Any of `bin`, `bin_sha`, `timestamp` absent prints
   `unrecorded` in its own field, matching `run.tl`'s deliberate refusal
   to write a placeholder into the data itself. `gap` is
   `format_gap(b_ts - a_ts)`, or `unrecorded` when either timestamp is
   missing.

4. Change `format`'s signature to `format(deltas: {pt.Delta}, prov:
   string): string` — the second parameter REQUIRED, not optional — and
   have it emit `prov`, a newline, then the table and summary line it
   emits today. Required is the point: the checker then refuses any
   call site that would print an unlabeled table, which is the wrong
   turn this whole slice exists to prevent. `format_delta` is
   UNCHANGED — the identity is one label per table, not a column
   repeated on ~36 identical rows, because the chaining hazard the Goal
   names is between the up-to-three tables one `gate_inner` run prints,
   not between rows of one table.

**In `_perf/gate.tl`.** `compare_once` already loads both results
files; give it a fourth return value, the `provenance(...)` line built
from the two it loaded, and pass it into every print. Measured today,
`git show origin/main:_perf/gate.tl | grep -c 'print(compare\.format(deltas))'`
is 4 — three in `gate_inner` (pass 1, the retry pass, the final
triaged pass) and one in `selfcheck`. All four become
`print(compare.format(deltas, prov))`, naming the local `prov`.

**In `_perf/run.tl`.** `run_compare` loads `base` and `cur` before it
formats; its single `print(compare.format(deltas))`
(`git show origin/main:_perf/run.tl | grep -c 'print(compare\.format(deltas))'`
is 1) becomes `print(compare.format(deltas, prov))` over a `prov` built
the same way. No compatibility dance is needed for the release lane's
bare `o/perf/prev/cosmic-lua _perf/run.tl --out …` step: that step
never enters `run_compare`, and a bare script resolves `_perf.compare`
from the older binary's embedded copy in any case, where an extra
argument to a one-parameter Lua function is discarded.

**In `_perf/compare_test.tl`.** Update the two existing
`compare.format(` calls
(`git show origin/main:_perf/compare_test.tl | grep -c 'compare\.format('`
is 2) to pass a fabricated provenance string, and add four tests:
`test_provenance_names_both_sides`,
`test_provenance_says_unrecorded_when_meta_is_absent`,
`test_format_gap_scales_and_signs`, and
`test_format_prepends_the_provenance`. The file is in RUNNER MODE:
runner-mode batch 1 (3IU6AZEx) landed as #1458 on 2026-08-27, so
`grep -c '^test_[A-Za-z0-9_]*()$' _perf/compare_test.tl` is 0 and each
new test is DEFINED and not called — no self-call line after its `end`
(D29). Re-run that grep at pull and match whatever the file is.

**In `skills/optimize/measurement.md`.** Add one bullet to the
existing list, no new heading and no `file:line` citation (the
citations lint pins those). It says two things: every table
`gate.tl compare` and `gate.tl selfcheck` print is now preceded by
`perf: base` / `perf: cur` lines carrying each side's binary sha,
measurement time and the gap between them, so a table measured across
two sessions is visible as one; and the founded rule behind it — cosmic
`d8492168…`, the same bytes, read median 191.31 µs in one session and
144.29 µs in another with disjoint ranges (+32.6%), so an absolute
reading of `codec_base64_roundtrip_64k` is reproducible within its own
session and is not comparable across sessions, and only a delta
measured between two binaries interleaved in ONE session is a claim.
Close the bullet with the wall in its own words: this is a reason to
READ the labels, never a reason to widen any bar.

**If the coverage ratchet complains**, run exactly the regen command
its failure message prints and commit the result — in scope, and never
a gate weakened any other way. Committed floors touched here, measured
today in `origin/main`'s `.cosmic-coverage` at `54aa87df`: `_perf/compare.tl` 105/107,
`_perf/gate.tl` 95/115, `_perf/run.tl` 97/191. Raising a covered count
is expected; a row for a file this diff does not touch must not move.

## Non-goals

- **No widening of `codec_base64_roundtrip_64k`'s noise floor**, and no
  change to any bar. 3IU0GxoA's evidence makes this scenario look MORE
  stable within a session, not less: its 40-run bracket is tighter than
  the ±4.8% figure 3ISlY5Xl's arithmetic used. 3ISlY5Xl held a release
  at +21.0% via `21.0 > max(10.0, 2 x 4.8)`, and the release lane
  measures baseline and candidate in the SAME job on the SAME runner —
  the interleaved shape the cross-session effect cannot reach. The
  20-33% cross-session spread is NOT a noise budget for that gate;
  treating it as one would retire the arithmetic that kept it honest
  over a regression two independent interleaved experiments have since
  confirmed.
- **No committed threshold may end larger than it starts.**
  `DEFAULT_THRESHOLD_PCT` stays `10.0` and `TRIAGE_K` stays `2.0`
  (measured 2026-08-27 at `origin/main` `54aa87df`,
  `git show origin/main:_perf/compare.tl | grep -n 'DEFAULT_THRESHOLD_PCT = \|^local TRIAGE_K'`
  → lines 19 and 27). No per-scenario floor is introduced:
  `grep -rn 'noise_floor' _perf` returns nothing today and must still.
- **The provenance line is informational and changes no decision.** It
  may not alter any verdict, `noise_pct`, failure count, or exit code,
  and it may not become a refusal or a warning when the gap is large —
  that would newly fail every legitimate compare against a baseline
  measured yesterday. `diff`, `triage`, `triage_many`,
  `identity_refusal` and `format_delta` keep their current behaviour,
  and `identity_refusal`'s existing missing-`bin_sha` stderr note stays
  where it is.
- **No per-scenario or history-derived noise floor, and no A/A history
  store.** That is 3IVDirCO, deliberately left in the backlog: the
  bounce below established that the gate persists no cross-window A/A
  history to derive one from, so the derivation the title names has no
  data source and building one is a decision nobody has taken.
- No D31 amendment and no new decision record: this slice settles no
  tradeoff about the bar.
- No scenario, `check()`, `--threshold` default, or `_perf/bench/**`
  change. No new CLI flag. No change to the `perf-compare: PASS/FAIL`
  or `perf-selfcheck:` verdict lines — `release.yml` greps them.
- `_perf/gate_test.tl` is not touched at all; the change needs no edit
  there.
- The interleaved A/B within one session
  (`skills/optimize/measurement.md`) stays the instrument of record for
  codec claims; nothing here replaces it.

## Acceptance

Run from the repo root. Nothing below writes into the committed tree;
the one measuring command writes only under `o/perf/`.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/compare_test.tl` passes, including
  `test_provenance_names_both_sides`,
  `test_provenance_says_unrecorded_when_meta_is_absent`,
  `test_format_gap_scales_and_signs` and
  `test_format_prepends_the_provenance`.
- `grep -c 'compare\.format(deltas, prov)' _perf/gate.tl` prints `4`
  (it prints `0` before the change).
- `grep -c 'compare\.format(deltas, prov)' _perf/run.tl` prints `1`
  (it prints `0` before the change).
- `grep -c 'compare\.format(deltas))' _perf/gate.tl _perf/run.tl`
  prints `_perf/gate.tl:0` and `_perf/run.tl:0` — no unlabeled table
  survives anywhere.
- `grep -n 'DEFAULT_THRESHOLD_PCT = \|^local TRIAGE_K' _perf/compare.tl`
  prints exactly `local DEFAULT_THRESHOLD_PCT = 10.0` and
  `local TRIAGE_K = 2.0`, unchanged.
- `grep -rn 'noise_floor' _perf | wc -l` prints `0`.
- `git diff origin/main -- _perf/compare.tl _perf/gate.tl _perf/run.tl | grep -c '^[-+].*\(TRIAGE_K\|DEFAULT_THRESHOLD_PCT\|noise_pct\)'`
  prints `0` — the diff touches no line of the noise arithmetic.
- `git diff --name-only origin/main | grep -c '_perf/gate_test.tl'`
  prints `0`.
- `wc -l _perf/compare.tl _perf/gate.tl _perf/run.tl _perf/compare_test.tl skills/optimize/measurement.md`
  shows every file at or under 500.
- End to end, one scenario, both label lines on a real table:

  ```
  bin/cosmic --make run _perf/gate.tl selfcheck o/perf/aa-a.json o/perf/aa-b.json \
    --only codec_base64_roundtrip_64k | tee o/perf/aa.txt
  grep -c '^perf: base \|^perf: cur ' o/perf/aa.txt
  ```

  The `grep` prints `2`, the label lines carry a 12-character `sha`
  (identical on both sides, since selfcheck measures one binary twice)
  and an ISO `measured` stamp on each, and `o/perf/aa.txt` ends
  `perf-selfcheck: nothing exceeded the bar — the machine is quiet at
  this threshold` or its noisy counterpart — either is a pass here.
  **The timings this run prints are not evidence of anything and may
  not be quoted as a measurement**: a single-window reading of this
  scenario is exactly what 3IU0GxoA established is not comparable to
  any other. Only the two label lines are under test.
- `o/perf/*.json` and `o/perf/*.txt` are not committed
  (`git status --short o/` prints nothing — `o/` is ignored).

## Enablement

None needed; no blocker item, and nothing is deferred to another
slice. The enablement check ran over this `Change`, and every
predicted wrong turn is answered inside it, core first:

- *Printing the label on only the first of the gate's three tables* —
  answered in CORE: `format`'s second parameter is REQUIRED, so the
  type checker refuses an unlabeled call, and the Acceptance greps
  count all five call sites.
- *Reading `meta.timestamp` back as nil forever because `shape.into`
  drops keys `RESULTS_SPEC` does not name* — answered by naming the
  `RESULTS_SPEC` edit as edit 1 and by
  `test_provenance_names_both_sides`, which asserts a real ISO stamp
  rather than `unrecorded`.
- *Growing the change into a stale-baseline refusal or a wider bar* —
  answered by the Non-goals and by three Acceptance commands that
  bound the noise arithmetic mechanically.
- *Adding a test to `_perf/gate_test.tl`, which is at the 500-line
  cap* — answered by measuring its zero headroom in `Change` and by
  designing the change so that file needs no edit.
- *`assert`ing the fallible `time.format_iso8601`, or reaching for an
  `as` cast to keep integers integers* — answered by naming `or
  "unrecorded"` and the explicit sign branch in edit 2 and 3.

Context to read before building: 3IU0GxoA's Result (the byte-identical
cross-session control table and its "What this does NOT license"
paragraph), 3ISlWFiS and 3ITOUv0w for the per-arm readings and hashes
that control rests on, and 3IVDirCO for the half deliberately not
built here. The gate and selfcheck machinery already exist (#1432).

The one landing-order constraint this slice had is GONE: 3IU6AZEx
(runner-mode batch 1) had `_perf` in its scope and removed the
self-call lines from `_perf/compare_test.tl`; it landed as #1458 on
2026-08-27 at 14:26 UTC, so that file is already runner mode and no
sibling slice is queued over these files. Nothing blocks this one.

## Bounce — 2026-08-27 14:2x UTC, returned to plan (session 0b13d2b4)

Pulled, re-measured, and returned unbuilt: the Change deferred its own
shape to plan twice and the Acceptance was unwritten, so there was
nothing that could be implemented from the spec alone. Retained as the
trail; the refinement above answers all three gaps — (1) Acceptance is
written, (2) part 1's printed shape and files are settled, (3) part 2
is cut out to 3IVDirCO on this bounce's own finding that no A/A
history store exists.

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

**Why it bounced, three gaps.**

1. **`## Acceptance` was unwritten** — it read "To be written at
   refinement, with the derivation command and its measured output
   quoted." The acceptance commands are the definition of done; with
   none, the slice had no closing condition and the reviewer no
   evidence to demand.
2. **Change part 1 deferred its own shape**: "the shape and the files
   to touch are to be settled at plan", and plan did not settle them.
   Today `_perf/compare.tl`'s `format_delta`/`format` print exactly the
   six fields above, and `meta.bin_sha` is read only by
   `identity_refusal`. Whether the identity lands as a report header,
   a per-row column, one side or both, short or full hex — and whether
   `format_delta`'s signature has to grow to carry it — is a design
   decision the spec reserved to plan.
3. **Change part 2's data source does not exist.** It asked for a floor
   derived "from the selfcheck files the gate already writes". The
   gate writes the two results files the CALLER names and persists no
   history: `_perf/gate.tl`'s `selfcheck` takes `A.json B.json`,
   measures into both, compares, and returns — nothing accumulates,
   and `o/perf/*.json` is never committed (AGENTS.md). There is no
   accumulated cross-window A/A history anywhere in the tree to derive
   a per-scenario floor from, so answering "does a history-derived
   floor improve on `spread_pct`" first requires DECIDING to build a
   history store and where it lives.

No tree diff and no PR: the branch cut for this slice
(`claude/3IUBNQZZ-noise-floors`, off `267c2a4d`) carries no commits.
