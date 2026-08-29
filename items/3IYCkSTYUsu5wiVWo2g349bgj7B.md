## Goal

G6 — every release measures the defining paths and answers for them
(this item's parent, `3HyRcd9F`). The result it serves: a release-gating
red is traceable to the change under test, and a release-gating green
means no scenario regressed — neither verdict decided by which of two
baseline readings the gate happened to pick.

## Change

Give the perf gate's baseline side a THIRD reading when its first two
disagree, and judge against the per-scenario median of the readings.
`_perf/gate.tl` and `_perf/gate_strike_test.tl` change;
`_perf/tiebreak.tl` and `_perf/tiebreak_test.tl` are new; one decision
record is added and D34 is marked superseded by it. The sections below
give the finding, the rule, the alternatives it beats, and each file's
edit. Everything numbered here was executed on 2026-08-28 and carries
the command that produced it.

**Re-measured at pull, 2026-08-29, on `origin/main@9048f3b6`** (after
`3IWU4i0l` landed as #1496). The shape holds unchanged: both probes
reproduce, byte for byte. Detail drift only, refreshed below —
`_perf/gate.tl` is **499**, not the 490/493 predicted (#1496 spent more
of the file than its own estimate), `_perf/compare.tl` is **483**,
`_perf/gate_strike_test.tl` is **303** with **ten** cases rather than
seven, `_perf/reproduce.tl` and `_perf/reproduce_test.tl` are new, and
the highest `dNN` on any branch is now **d35**, so the new record is
**D36**. `_perf/tiebreak.tl` therefore lands `_perf/gate.tl` at
**498** — one line under what it found, and under the cap — so the
capacity question `3IYCQxfH` raises does not block this item.
`_perf/compare.tl`'s constants moved one line each (`DEFAULT_THRESHOLD_PCT
= 10.0` at line 20, `TRIAGE_K = 2.0` at line 28) and did not change
value. One further edit the frozen spec could not have named: D35 did
not exist when it was written, and D35's rejected list refers the
baseline-pair credit forward as "still the instrument that fixes the
false red D34 accepted" — which this item disproves — so D35 gets an
appended amendment bullet and its status set, per `skills/decide`'s
both-ways-pointer rule. Its decision is untouched.

### The finding: two readings have no majority, and the current side is silent

`gate_inner` reads the baseline binary twice — the caller's
`opts.baseline` file and the `--baseline-bin` retry — and refuses the
run outright when they name different binaries
(`_perf/gate.tl`, `identity_refusal(opts.baseline, base_side, true)`).
When those two same-binary readings disagree past the bar, nothing
decides which of them is the outlier. D34 chose the retry, which is
right for the case D34 settled and leaves the disagreement itself
unresolved.

D34 deferred one instrument for that disagreement — "also give the
baseline PAIR its own noise credit", its third rejected option, recorded
as *correct, and better; rejected here as a separate slice rather than
forever*, and filed as `3IWx3I4Z`. **That instrument cannot work, and
neither can any other function of the two readings.** Two facts, both
measured.

**1. The linear credit is contradictory.** Feed each of D34's two pinned
fixtures' baseline pair in as a control group and read `triage_many`'s
rule `|reg| <= max(noise_pct, TRIAGE_K * |control|)`. Measured by a
throwaway probe over `compare.diff` at `origin/main@40776231`, in
`loudest_control`'s own pair orientation (`diff(controls[i],
controls[j])`):

```text
false-red :169     reg=+42.8571%  ctrl=-30.0000%  |reg|/|ctrl|=1.4286  K=2 credits? true
masked-reg :144    reg=+30.0000%  ctrl=-23.0769%  |reg|/|ctrl|=1.3000  K=2 credits? true
TRIAGE_K = 2.0
```

Re-run 2026-08-29 on `origin/main@9048f3b6`: identical to the digit,
including `TRIAGE_K = 2.0`.

`:169` is `test_a_one_off_fast_baseline_retry_fails_the_gate`, the false
red D34 knowingly accepts and this item exists to remove. `:144` is
`test_masked_baseline_regression_still_fails`, the regression D34 landed
to unmask. At `TRIAGE_K = 2` both are credited, so `gate_inner` returns 0
and D34's decision is undone. Crediting the first needs `K >= 1.4286`;
denying the second needs `K < 1.3000`. The interval is empty, and the
ordering runs backwards: tightening `K` denies the false red before it
denies the masked regression. The `3IWx3I4Z` block reason reproduces
exactly.

**2. No formula over the pair separates them, because the two cases can
be made the SAME measurement.** Both fixtures have the shape "current
side steady and equal to the pass-1 baseline reading; the baseline retry
the sole dissenter", so the gate's whole input reduces to two readings of
the baseline binary with a current side that agrees with one of them by
construction. Deciding is exactly deciding which baseline reading is the
outlier, and that fact is not in the data. Driven end to end through
`gate.gate` with a probe that runs the two ground truths on
byte-identical inputs — driver `a` 1000 -> 1300 to reach the retry path,
scenario `x` reading baseline 1000, baseline retry 700, both current-side
runs 1000, differing ONLY in the third baseline reading:

```text
PROBE C identical-two-sample-inputs: third=1000 -> 0   third=700 -> 1
```

Re-run 2026-08-29: the UNCHANGED gate answers `third=1000 -> 1
third=700 -> 1` — it gives one verdict to both ground truths, which is
the finding — and the implemented change answers `third=1000 -> 0
third=700 -> 1`, reproducing the prototype's figure exactly.

`third=1000` is the false red (the 700 was the one-off; no regression,
gate must pass). `third=700` is a real +42.9% regression that a one-off
SLOW pass-1 baseline reading of 1000 masked (gate must fail). Same two
readings, same current side, opposite correct verdicts. A third reading
is not one instrument among several; it is the only one.

### The rule this change installs

On the `--baseline-bin` path only, after the baseline retry and its
identity check:

- if the two readings agree everywhere under the bar, the retry IS the
  baseline side, exactly as today, and **no third pass is measured**;
- if they disagree on any scenario, measure the baseline binary a third
  time into the baseline's `-retry2.json` sibling, refuse it under the
  same `identity_refusal(..., same = true)` rule if it named another
  binary, write the per-scenario MEDIAN of the three readings to the
  `-median.json` sibling, and judge passes 2 and 3 against that.

Median of three is "the majority decides which reading was the outlier",
which is the discriminator PROBE C isolates. A scenario missing from a
reading, or carrying an error there, keeps the first reading's row
verbatim — the median is a tiebreak over comparable numbers, not a way to
invent one. Everything downstream is untouched: `flagged_first` is still
re-keyed to whatever `base_side` ends up being (D34's re-key, unchanged),
`TRIAGE_K` and the 10% bar do not move, and no new noise credit is
created anywhere.

### The cost, measured on the release runner

A third baseline pass is a full measurement pass, and this item is the
one that must decide whether the gate buys it. It does, and the budget
says it can. From the release workflow's own step timings:

| what | where | seconds |
|---|---|---|
| two measurement passes | run `33098467706`, step "measure the release", 17:29:01 -> 17:31:17 | 136 (≈68/pass) |
| gate step, clean path (download + one baserun pass) | same run, "compare against the previous release", 17:31:17 -> 17:32:30 | 73 |
| gate step, one current-side retry taken | run `33034667243` attempt 3, same step, 03:25:42 -> 03:27:55 | 133 |
| one full pass, this container | `cosmic _perf/run.tl --out o/perf/p1.json` | 65 (re-measured 2026-08-29: 65) |

The gate step carries `timeout-minutes: 15` (900 s). Today's worst case
is baserun + retry + baseline retry + selfcheck-b ≈ 73 + 3 x 68 ≈ **277 s**.
With the third reading ≈ **345 s**, 38% of the budget, ~9 minutes of
headroom left. On the clean path — pass 1 flags nothing, which is what a
release normally does — the cost is **zero**: the gate never reaches the
retry at all.

Why the baseline side takes a third pass where `3IWU4i0l` refused one on
the current side: `3IWU4i0l` found a decision rule over files ALREADY on
disk (the dismissal-credit rule), so measurement bought nothing there.
Here PROBE C proves no such rule exists, so measurement is the only
instrument left. The cost discipline is the same in both: the extra pass
is taken only inside a narrow condition (here, a baseline pair that
actually disagrees) on a run that has already flagged a regression.

### Why this fix and not the alternatives

- **Give the baseline pair its own noise credit** (D34's third rejected
  option, `3IWx3I4Z`). Disproved above: it credits the masked regression
  too and undoes D34. After this change lands, `3IWx3I4Z` needs
  re-refinement — its suite-scale level-shift concern survives, its
  instrument does not.
- **Spend the pair as a `noise_pct` widening** (bar = `max(10,
  |control|)`). Denies both: `42.86 > 30` keeps the false red and
  `30 > 23.08` keeps D34 intact. Sound and useless.
- **A non-linear credit with a knee between the two control swings.**
  Arithmetically possible (credit above ~26%, deny below) and rejected:
  it asserts that a 30% baseline swing is noise while a 23% one is real,
  which is not a fact about anything, and PROBE C shows the knee has
  nothing to key on once the two cases are put on identical numbers.
- **Always take three baseline readings.** Costs the third pass on every
  gate run that reaches the retry, including the runs whose pair agrees
  and where the median changes nothing. The conditional is a strict
  saving with no behaviour difference.
- **Do nothing and let D34's false red stand.** D34 named the trigger to
  revisit — repeated reds traceable to the baseline retry — and no such
  release run is recorded on the board, so on the false red ALONE this
  would be premature. It is not the whole case: the same disagreeing pair
  is what `3IWx3I4Z`'s suite-scale level shift produces (`3IU0GxoA`
  measured 20-33% level moves on a byte-identical binary between
  sessions, well past the 10% bar), and that item is blocked on this one
  with no other route. Buying the third reading closes both and is the
  only thing that does.

### Files

Line numbers and counts are on the MERGED tree — `origin/main@40776231` +
`origin/claude/3IUBNQZZ-compare-rows` (#1485) +
`origin/claude/3IVLAF3Z-stampless-identity-v2` (#1486), tree
`73633bea`, committed as `d164e4d1` — plus `3IWU4i0l`, which this item is
blocked on (see `## Enablement`).

1. **`_perf/tiebreak.tl`** — NEW module, 188 lines as landed (the
   prototype was 137), owning the whole
   question "what is the baseline side":
   - `disagrees(a: pt.Results, b: pt.Results, threshold: number): boolean`
     — true when `compare.diff(a, b, threshold)` gives any scenario a
     `regression` or `faster` verdict. The same binary against itself
     should read `ok` everywhere.
   - `median_of(runs: {pt.Results}): pt.Results` — per-scenario median
     over the readings, `meta` from the first. A row not present with a
     `wall_ns` and no `error` in EVERY run is carried from the first run
     unchanged.
   - `baseline_side(baseline: string, threshold: number, measure:
     function(out: string): integer): string | nil, string` — derives the
     `-retry.json` / `-retry2.json` / `-median.json` siblings from
     `baseline` by replacing a trailing `.json`; prints the existing
     `perf-compare: re-measuring the baseline into ...` line, measures,
     loads both, applies `compare.identity_refusal(baseline, a, retry, b,
     true)`, returns `retry` when `disagrees` is false, and otherwise
     prints one new line, measures the third, identity-checks it the same
     way, writes `median_of({a, b, c})` and returns the median path. On
     any failure it returns `nil` and the message.
2. **`_perf/gate.tl`** — 499 -> **498** (re-measured 2026-08-29; the
   frozen figures were 490 -> 488), one line SMALLER than it found
   the file. Add `local tiebreak = require("_perf.tiebreak")` beside the
   other requires. Replace the whole `if opts.measure_baseline then ...
   end` block in `gate_inner` — the `base_side = retry_path(...)`
   assignment, its print, the `opts.measure_baseline` call and its rc
   check, and the identity check, all of which move into
   `baseline_side` — with one `tiebreak.baseline_side(opts.baseline,
   opts.threshold, opts.measure_baseline)` call, a nil check writing the
   message to stderr and returning 1, and `base_side = resolved`. Keep a
   house-style comment block at the site: the existing "a one-off reading
   anchors every later pass" paragraph plus why two readings need a
   third. Rewrite the module header's "when the caller can re-run the
   baseline binary" sentence to state the median rule. `retry_path` stays
   — the current-side retry still uses it.
3. **`_perf/tiebreak_test.tl`** — NEW, 152 lines as landed (the
   prototype was 112), nine cases:
   `disagrees` under and over the bar in the `faster` direction; the
   median following the majority in both directions; a row missing from
   one reading carried through; an agreeing pair costing exactly ONE
   `measure` call and returning the `-retry.json` path; a disagreeing pair
   costing exactly TWO and returning the `-median.json` path whose written
   file carries the majority number; a third reading naming another binary
   refused with the `DIFFERENT binaries` message; a failed measurement
   reported rather than swallowed.
4. **`_perf/gate_strike_test.tl`** — 303 -> **313** (re-measured
   2026-08-29; the frozen figures were 214 -> 219), two fixtures:
   - `test_a_one_off_fast_baseline_retry_fails_the_gate` becomes
     `test_a_one_off_fast_baseline_retry_is_outvoted`. Its
     `measure_baseline` closure counts calls and writes `x = 700` only on
     the FIRST — as written it repeats the "one-off" on every call, which
     is a fixture that cannot model a one-off. Asserts `code == 0` and
     `bcalls == 2`. **This is the mutation test** (measured below).
   - `test_baseline_retry_rescues_a_one_off_baseline_reading` keeps its
     numbers; `bcalls == 1` becomes `bcalls == 2` (its pair disagrees by
     +30%, so it earns the third reading) and `bpath` records the FIRST
     out path (`bpath = bpath or out`) so its `-base-retry.json`
     assertion still names the retry.
   - The other EIGHT stand unchanged (#1496 added three cases),
     including
     `test_masked_baseline_regression_still_fails`,
     `test_baseline_retry_naming_a_different_binary_is_refused` (its
     refusal still fires after exactly one baseline call) and
     `test_current_side_instability_absorbs_the_fast_baseline_retry`.
5. **`docs/decisions/dNN-*.md` + `docs/decisions/README.md`** — a NEW
   record that SUPERSEDES D34, per `skills/decide/SKILL.md`'s
   amend-versus-supersede rule: D34's decision clause is "the
   reproduction rule reads ONE baseline — the re-measured one", and this
   replaces which baseline that is, so the call itself moves. Set D34's
   `status` to `superseded by D<n>` and leave its body exactly as
   written. The new record restates the half of D34 that survives (two
   independent current-side samples, one common baseline), carries the
   two measurements above as its context, and lists the four alternatives
   above with the reason each lost. Its consequences must name the real
   costs: one extra measurement pass on a gate run whose baseline pair
   disagrees, and a median that can still be wrong when two of three
   readings are outliers together — a suite-wide level shift lasting two
   of the three passes. Take the next free number after checking EVERY
   remote branch, not just main: `for b in $(git branch -r
   --format='%(refname:short)' | grep -v HEAD); do git ls-tree
   --name-only $b docs/decisions/; done` returns `d34` as the highest on
   2026-08-28, and `3IWU4i0l` — which lands first — claims one too, so
   re-run it rather than assuming `d35`. Re-run 2026-08-29: `d35` is the
   highest, taken by #1496, so this record is **D36**. Regenerate the
   index with `bin/cosmic _docs/derive.tl`.

### Measured facts, 2026-08-28

Every row was produced by the command beside it, on one container, today.

| fact | command | value |
|---|---|---|
| today's main | `git log --oneline -1 origin/main` | `40776231` |
| #1485 head | `git rev-parse --short origin/claude/3IUBNQZZ-compare-rows` | `37ea41cb` |
| #1486 head | `git rev-parse --short origin/claude/3IVLAF3Z-stampless-identity-v2` | `2a29c4d3` |
| the two PRs merge onto main | `git merge-tree --write-tree --messages origin/main origin/claude/3IUBNQZZ-compare-rows`, then that tree as a commit against `...3IVLAF3Z-stampless-identity-v2` | rc 0 both; tree `73633bea` |
| `_perf/gate.tl` | `git show origin/main:_perf/gate.tl \| wc -l` / `git cat-file -p 73633bea:_perf/gate.tl \| wc -l` | 460 / **490**; re-measured 2026-08-29 on `9048f3b6`: **499** |
| `_perf/gate.tl` AFTER this change | `wc -l` on the prototype in the merged worktree | **488**; as landed on `9048f3b6`: **498** |
| `_perf/compare.tl` | same | 357 / 416; re-measured 2026-08-29: **483**, still **unchanged** by this item |
| `_perf/gate_strike_test.tl` | same | 214 / 214 -> **219**; re-measured 2026-08-29: 303 -> **313** |
| prototype vs #1485 | `git merge-tree --write-tree --messages <proto> origin/claude/3IUBNQZZ-compare-rows` | **rc 0**, `Auto-merging _perf/gate.tl` |
| prototype vs #1486 | same, `...3IVLAF3Z-stampless-identity-v2` | **rc 0**, `Auto-merging _perf/gate.tl` |
| prototype vs both merged | same, against `d164e4d1` | **rc 0**; `_perf/gate.tl` 488 |
| the whole `_perf` suite, merged tree + prototype | `cosmic --make test _perf` | `14 checks: 14 passed` / `test: PASS (14 files)`; re-measured 2026-08-29: `15 checks: 15 passed` / `test: PASS (15 files)` |
| the same on plain `origin/main` + prototype | `cosmic --make test _perf` | `test: PASS (13 files)` — no API from either PR is used |
| `_perf/gate.tl` coverage floor | `grep _perf/gate.tl .cosmic-coverage` | `covered = 164, total = 208`; unchanged 2026-08-29, and `_perf/tiebreak.tl` enters the baseline at 77/82 |
| highest `dNN` on any branch | the all-branches `ls-tree` above | `d34`; re-measured 2026-08-29: **`d35`** |

**The mutation.** With `_perf/gate_strike_test.tl` at its post-change text
and `_perf/gate.tl` / `_perf/tiebreak.tl` reverted, `cosmic --make test
_perf/gate_strike_test.tl` on the merged tree reports:

```text
  failing tests:
    ✗ test_baseline_retry_rescues_a_one_off_baseline_reading
        a disagreeing baseline pair earns a third reading, got 1
    ✗ test_a_one_off_fast_baseline_retry_is_outvoted
        a one-off fast baseline retry must be outvoted, got 1
    7 checks: 5 passed, 2 failed
test: FAIL (1 of 1 file)
```

With the change in place the same command reports `test: PASS (1 file)`.

**Do not weaken the median to make a fixture pass.** Every one of the
seven strike cases, all seventeen `gate_test` cases, `gate_identity_test`
and `compare_test` pass against the prototype as described; a red one is
a defect in the change.

## Non-goals

- **Do not give the baseline pair a noise credit, and do not add a second
  control GROUP to `triage_many`.** That is the instrument this item
  disproves. No baseline-versus-current pair is formed anywhere.
- **Do not change `TRIAGE_K`, `DEFAULT_THRESHOLD_PCT`, `diff`'s verdict
  vocabulary, `loudest_control`, `triage_many`, `format`, `format_delta`,
  `format_identity`, `load_results` or `same_binary`.** `_perf/compare.tl`
  is READ by this change and not edited. D31 governs how much variance a
  scenario is credited for and stands unamended; this change creates no
  credit at all.
- **Do not touch the current side.** The retry, the A/A self-check, the
  three control pairs, `flagged_first`'s re-key and the strike-twice loop
  keep their exact behaviour. `3IWU4i0l` owns the current-side sampling
  question and lands first.
- **Do not change the number of passes on the clean path, or on a run
  whose two baseline readings agree.** Both stay exactly what they are
  today. The third pass is conditional and that is the point.
- **Do not touch `.github/workflows/release.yml`, `_perf/run.tl`,
  `_perf/baserun.tl`, `_perf/baseline.tl` or `_perf/harness.tl`.** The
  gate's CLI, its `--baseline-bin` flag and its one caller
  (`release.yml:188`) are unchanged; `grep -c 'baseline-bin'
  .github/workflows/release.yml` is 1 before and after.
- **Frozen output contracts**: the `perf-compare: PASS` / `perf-compare:
  FAIL` verdict lines, `compare.format_delta`'s row layout and
  `compare.format`'s summary line are parsed downstream. New text is added
  only as new `perf-compare:` message lines. The existing
  `perf-compare: re-measuring the baseline into ...` line keeps its
  wording when it moves into `_perf/tiebreak.tl`.
- **One behaviour change, deliberate and pinned:** a failed baseline
  re-measurement now exits 1 with a printed message instead of
  propagating the runner's own exit code. `release.yml` branches on
  nonzero, so it is unobservable at the one caller, no test covered it,
  and `test_a_failed_measurement_is_reported` pins it. The CURRENT-side
  `measure` rc still propagates unchanged —
  `_perf/gate_test.tl:test_measure_failure_propagates` must stay green.
- **Do not widen the 500-line cap, add a lint exemption, split
  `_perf/gate.tl`, or fold `3IYCQxfH` in.** The change is designed to
  leave `_perf/gate.tl` smaller than it found it.
- **Do not weaken any scenario, its `check()`, or its numbers.** No
  per-scenario floor, no per-bench opt-out, no widened default bar.
- Do not touch `.cosmic-coverage` except by running the exact regen
  command a coverage-ratchet failure prints
  (`bin/cosmic --make coverage --baseline`), and commit that result.

## Acceptance

Run from the repo root. Each command must end with the verdict line given.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf` ends `test: PASS` with zero failing
  checks. It reported `test: PASS (13 files)` on `origin/main` before this
  item and `test: PASS (14 files)` with `_perf/tiebreak_test.tl` added;
  `3IWU4i0l` adds `_perf/reproduce_test.tl`, so the count is 15 once both
  have landed — the file COUNT is not the contract, the verdict is.
  Re-measured 2026-08-29: `test: PASS (15 files)`, as predicted.
- `bin/cosmic --make test _perf/gate_strike_test.tl` ends
  `test: PASS (1 file)`, including
  `test_a_one_off_fast_baseline_retry_is_outvoted` — **the mutation
  test**: with `_perf/gate.tl` and `_perf/tiebreak.tl` reverted it fails
  with `a one-off fast baseline retry must be outvoted, got 1`, and it
  passes with them in place.
- `bin/cosmic --make test _perf/tiebreak_test.tl` ends
  `test: PASS (1 file)`.
- `bin/cosmic --make test _perf/skew_test.tl` ends `test: PASS (1 file)` —
  `_perf/tiebreak.tl` is a non-test `_perf` module and must type-check
  under the pinned bootstrap.
- `bin/cosmic --make test _perf/gate_test.tl` ends `test: PASS (1 file)`,
  including `test_measure_failure_propagates`.
- `bin/cosmic --make test _build/docs_test.tl` ends `test: PASS (1 file)`
  — the derived decision index matches the records, after
  `bin/cosmic _docs/derive.tl`.
- `wc -l < _perf/gate.tl` is at most 500, AND at most
  `git show origin/main:_perf/gate.tl | wc -l` — this change must not
  grow the file. Measured: 460 on `origin/main@40776231`, 490 on the
  merged tree of #1485 + #1486, 488 with this change on that tree.
  Re-measured 2026-08-29: `3IWU4i0l` (#1496) took it to **499**, and
  this change lands it at **498**.
- `wc -l _perf/tiebreak.tl` is at most 500. The prototype was 137; as
  landed, 188.
- `wc -l _perf/tiebreak_test.tl` is at most 500. The prototype was 112;
  as landed, 152.
- `git diff --name-only origin/main...HEAD -- _perf/compare.tl` prints
  nothing: this item does not edit `_perf/compare.tl`.
- `git grep -n 'DEFAULT_THRESHOLD_PCT = \|TRIAGE_K = ' _perf/compare.tl`
  still shows `DEFAULT_THRESHOLD_PCT = 10.0` and `TRIAGE_K = 2.0` —
  lines 19 and 27 when frozen, lines 20 and 28 on `9048f3b6`; the VALUES
  are the contract, not the lines.
- `git grep -nE 'noise_floor|threshold_pct *=' -- _perf/bench` prints
  nothing. It prints nothing today.
- `grep -c 'baseline-bin' .github/workflows/release.yml` is 1. It is 1
  today.
- `grep -c 'superseded by D' docs/decisions/d34-reproduction-against-remeasured-baseline.md`
  is 1.

`_perf/gate_strike_test.tl` and `_perf/tiebreak_test.tl` differ in mode:
the strike file is a runner-mode file (D29), so `grep -c '^test_'
_perf/gate_strike_test.tl` returns 0 and that is correct — only
`--make test` runs it, and a bare `o/bin/cosmic _perf/gate_strike_test.tl`
is a silent no-op (`3IUKyP4L`). `_perf/tiebreak_test.tl` follows
AGENTS.md's rule and calls each test on the line after its `end`.

## Enablement

Blocked on `3IWU4i0l` (`ready`), which is itself blocked on `3IUBNQZZ`
(#1485) and `3IVLAF3Z` (#1486). Nothing else is needed.

- **`3IWU4i0l` — ordering, real.** Its frozen `ready` spec anchors its
  insertion "after the baseline retry and its identity check" and quotes
  `_perf/gate.tl:305-316`. This change DELETES that identity check from
  `_perf/gate.tl` (it moves into `baseline_side`), so landing first turns
  its detail drift into value drift and bounces it. Its own capacity
  measurement (`_perf/gate.tl` at 493 after its change) is why the order
  also runs this way round: this item takes the merged 490 down to 488,
  so on top of `3IWU4i0l` it lands at ~491 with room, whereas the reverse
  order would put `3IWU4i0l` over the cap.
- **#1485 and #1486 — not blockers, measured.** The prototype merges
  clean against each (`git merge-tree --write-tree --messages` rc 0, no
  conflict message) and against both together, and the whole `_perf`
  suite passes on plain `origin/main` + prototype, so no API either PR
  introduces is used. The one place they touch this change is
  `compare.identity_refusal`: #1486 makes a STAMPLESS same-binary pair a
  refusal rather than a silent pass. `baseline_side` calls exactly the
  rule `_perf/gate.tl` calls today, at the same strength, for both the
  retry and the third reading — so it inherits #1486's fix for free when
  #1486 lands and adds no new stampless exposure before that.
- **`3IYCQxfH` — not a blocker.** The `_perf/gate.tl` cap problem is real
  and this change is designed around it rather than into it: the file
  ends smaller than it started. The split stays that item's to make.
- No new lint, fixture, guide or skill is needed. `_perf/skew_test.tl`
  already gates that a new non-test `_perf` module loads under the pinned
  bootstrap, `.cosmic-coverage` already ratchets a new file, and
  `--check lint` already enforces the 500-line cap and the cast
  justifications — the prototype passes `--check lint` and `--check fmt`
  on every file it touches.
