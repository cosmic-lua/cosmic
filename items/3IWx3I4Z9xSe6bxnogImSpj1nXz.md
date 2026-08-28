## Goal
G6 — every release measures the defining paths and answers for them. This
item's parent is that root. The result it serves: a release-gating red is
traceable to the change under test, not to the runner's clock.

## Evidence

D34 (PR #1483, item `3IVL9t0P`) re-keys the perf gate's strike-twice rule
to the re-measured baseline. Its **third rejected option** — "also give the
baseline PAIR its own noise credit" — is recorded as *correct, and better;
rejected here as a separate slice rather than forever*, and this item is
that slice.

The mechanism, as D34 states it: `opts.baseline` and `base_side` measure the
SAME binary by construction — `gate_inner` refuses the retry outright when
they do not (`_perf/gate.tl`, the `identity_refusal(opts.baseline, base_side,
true)` check) — so their disagreement is a legitimate A/A control. Reading it
would absorb, at its source, the false red D34 knowingly accepts and pins in
`_perf/gate_strike_test.tl:169`
(`test_a_one_off_fast_baseline_retry_fails_the_gate`).

The suite-scale case the capture named is still real and still unnamed
elsewhere: a uniform level shift between the two baseline runs (the runner's
clock or thermal state moving mid-job) moves every scenario in `base_side`
together, so both current-side samples flag the same broad set while every
control pair — all current-binary — stays quiet. Item `3IU0GxoA` measured
level moves of 20-33% on a byte-identical binary between sessions, well past
the 10% bar.

## What this refinement measured (2026-08-28)

Capacity, against the two PRs standing in `check` — `#1485` (`3IUBNQZZ`) and
`#1486` (`3IVLAF3Z`). Both branch from `3ff022d3`, where `_perf/gate.tl` is
blob-identical to `origin/main` (`4561df2b87c65dbf8dcfe4e4e1ece091227785ea`),
and both merge clean. Merged with `git merge-tree --write-tree` and counted
off the resulting tree:

```
git merge-tree --write-tree origin/main pr/1485                 # rc 0
git merge-tree --write-tree <that tree as a commit> pr/1486      # rc 0
git cat-file -p <tree>:_perf/gate.tl | wc -l      # 490  (10 free of 500)
git cat-file -p <tree>:_perf/compare.tl | wc -l   # 416  (84 free)
git cat-file -p <tree>:_perf/stats.tl | wc -l     # 127  (373 free)
```

`3IVLAF3Z`'s spec estimates 491/9; the merge-tree count is 490/10. Either
way `_perf/gate.tl` is the binding file.

**The smallest plumbing that would carry a second control group, counted
line by line against that merged text.** `compare_once`
(`_perf/gate.tl:82-104` in the merged tree) loads a flat `control_paths`
list; a second group means it takes `{{string}}` and loads per group. The
existing load block is 11 lines; the per-group version is 15 (the outer
`for`, a per-group table, and `#groups > 0` in place of `#control_paths >=
2`), so +4. The `@param` line has to be reworded past 90 columns, so +1. The
call site at `:295-299` needs the baseline group built and passed, +4. Total
**+9 lines, 490 to 499, with not one line of comment** — in the function
whose neighbouring decision already carries a twelve-line comment block
(`:283-294`) and directly under D34's reasoning. Any reviewer asking for the
house commentary on why the baseline pair is a control puts the file over
the cap. Capacity alone would make this a split-first item.

## Why it cannot be specified yet: the instrument absorbs D34's own guarantee

Capacity is not the blocker that matters. **The credit this item proposes
cannot tell D34's false red apart from D34's masked-baseline regression,
because over the two fixtures D34 pinned they are the same measurement.**

Both fixtures are in `_perf/gate_strike_test.tl` (unchanged by either PR in
`check` — 214 lines on `origin/main` and in the merged tree). Both have a
perfectly steady current side, a baseline pair that disagrees, and the
baseline retry reading FASTER than the baseline file. Only the ground truth
differs, and nothing in the job knows it.

**Fixture A — `test_a_one_off_fast_baseline_retry_fails_the_gate` (`:169`),
the false red this item exists to remove.** Scenario `x`: baseline 1000,
baseline retry 700, every current-side run 1000. Final regression is
`base_side` 700 to retry 1000 = **+42.86%**. Baseline pair is 1000 to 700 =
**-30.0%**.

**Fixture B — `test_masked_baseline_regression_still_fails` (`:144`), the
regression D34 landed to unmask.** Scenario `b`: baseline 1300, baseline
retry 1000, every current-side run 1300. Final regression is `base_side`
1000 to retry 1300 = **+30.0%**. Baseline pair is 1300 to 1000 =
**-23.08%**.

`triage_many`'s rule is `|regression| <= max(noise_pct, TRIAGE_K *
|control|)` with `noise_pct` 10 and `TRIAGE_K` 2.0
(`_perf/compare.tl:19,27`). Feed each fixture's baseline pair in as a second
control group:

- A: `42.86 <= max(10, 60.0)` — credited. The intended fix; the test at
  `:169` flips to PASS and would be rewritten, which is expected.
- B: `30.00 <= max(10, 46.15)` — **also credited**. `failures` reaches 0
  before the strike-twice loop, `gate_inner` returns 0, and
  `test_masked_baseline_regression_still_fails` fails. D34's entire decision
  is undone by the slice D34 deferred.

And no retune saves it inside the frozen form. Granting A needs `K >=
42.857/30 = 1.4286`; denying B needs `K < 30/23.077 = 1.3000`. The interval
is empty, and B's ratio is the SMALLER of the two — so tightening `K` denies
the false red its credit before it denies the masked regression. A rule that
separated them would need a non-scale-free step somewhere between a 23% and
a 30% control swing, which is fitting these two numbers rather than
measuring anything.

Note what this rules out and what it does not. Spending the baseline pair as
a widening of the scenario's own `noise_pct` instead (bar = `max(10,
|control|)`) keeps D34 intact — B: 30 > 23.08, still a regression — but does
not deliver the item either: A's +42.86% still clears a 30% bar. Sound and
useless. The only discriminator that is real evidence rather than curve
fitting is a THIRD baseline sample, so a majority of readings decides which
of the two is the outlier. That is more measurement, not more reading, and
it is a different and larger slice with its own release-time cost.

**This derivation was not executed.** It is arithmetic over the fixtures'
literal numbers and `triage_many`'s formula, both quoted above with file and
line. Nothing was built, no source file was touched, and the perf harness
was not run (absolute readings are not comparable across sessions —
`3IU0GxoA`). To confirm it, add the group and run
`bin/cosmic --make test _perf/gate_strike_test.tl`; the prediction is that
`test_masked_baseline_regression_still_fails` fails.

## What would unblock it

Two routes, and the choice between them is not a refinement's to make:

1. **A decision record.** D34 is `active` and its `decision` clause is
   precisely that the masked-baseline regression must fail. Accepting the
   re-masking above amends or supersedes it, which is the `decide` skill's
   form, not a slice's `Change` section. That record would have to answer
   D34's own cost argument — a false green is absorbed into tomorrow's
   baseline and never re-asked, a false red costs one workflow re-run — with
   evidence that the reds are now the expensive error. D34 already names
   that trigger: *repeated release reds traceable to the baseline retry
   rather than to the change under test.* No such run has been recorded on
   the board.
2. **A third baseline sample**, making the baseline side a real control
   GROUP rather than a pair, so the outlier is identified instead of
   averaged. This is a different item: it changes what `release.yml`
   measures and what a gate run costs, and it needs its own measurement
   before it can be sized.

Until one of those exists, this item stays in `plan`. It is not a
duplicate of `3IWU4i0l` (D34's closing "what this does NOT fix" — the
current-side sampling budget, a false GREEN, in `gate_inner`); the two are
opposite error directions in different functions and both should live.

## The wall: what this must never license

This item gives noise credit, so every mistake it can make runs toward
passing. `3ISlY5Xl` holds a release blocked at +21.0% via `21.0 > max(10.0,
2 x 4.8)`; that arithmetic is what keeps the gate honest and this item may
not retire any part of it.

- No committed threshold ends larger than it starts. `DEFAULT_THRESHOLD_PCT`
  stays 10.0 and `TRIAGE_K` stays 2.0, byte-identical.
- No per-scenario floor, no per-bench opt-out, no widened default bar.
- No scenario, its `check()`, or its numbers weakened to make a gate pass.
- No credit from any pair that is not same-binary by construction. The
  baseline pair qualifies only because `identity_refusal(opts.baseline,
  base_side, true)` already refuses the run when it does not hold; a pair
  that reaches the credit through a stampless file is `3IVLAF3Z`'s subject
  and stays refused.
- Nothing here licenses relaxing D34, D31 or `3ISlY5Xl` as a side effect of
  landing a helper. The re-masking above is the decision, and it is made in
  a record or not at all.

## Bounds any future spec must carry, as commands

Whatever shape this eventually takes, these belong in its `Acceptance`
verbatim, each with the value it returns today (2026-08-28, `origin/main` at
`40776231`):

- `git grep -nE 'noise_floor|threshold_pct *=' -- _perf/bench` prints
  nothing. Returns nothing today.
- `git grep -n 'DEFAULT_THRESHOLD_PCT = \|TRIAGE_K = ' _perf/compare.tl`
  still shows `DEFAULT_THRESHOLD_PCT = 10.0` (line 19) and `TRIAGE_K = 2.0`
  (line 27).
- `wc -l _perf/gate.tl` is at most 500. It is 460 on `origin/main` and 490
  in the merged tree of `#1485` + `#1486`.
- `bin/cosmic --make test _perf/gate_strike_test.tl` passes, INCLUDING
  `test_masked_baseline_regression_still_fails` — or, if a decision record
  has retired that guarantee, the test the record replaces it with.
- `bin/cosmic --make ci` ends `ci: PASS`.

`_perf/gate_strike_test.tl` is a runner-mode file (D29): `grep -c '^test_'
_perf/gate_strike_test.tl` returns 0 and that is correct — the runner
invokes the cases. AGENTS.md's "test files call each test where they define
it" omits that mode (`3IY0HUUk`). Only `--make test` runs it; a bare
`o/bin/cosmic _perf/gate_strike_test.tl` is a silent no-op (`3IUKyP4L`).

## Non-goals

- No change to `diff`, `format`, `format_delta`, `identity_refusal` or
  `load_results`.
- No change to what `release.yml` measures, or to the number of measurement
  passes a gate run costs — that is route 2 above and a different item.
- No re-litigation of D31's credit form or D34's re-key. Both stand until a
  record says otherwise.
- No `_perf/gate.tl` split folded into this item. If a split is what buys
  the room, it is `3IYCQxfH`, landed on its own.

## Enablement

Blocked, and the blockers are named above rather than filed as edges, since
neither is a slice this item can simply wait behind:

- **The decision** (route 1) is a `decide` pass over D34, not board work
  with a `Change` section. Whoever takes it writes the record first.
- **Capacity** is real independently: `_perf/gate.tl` reaches 490/500 the
  moment `#1485` and `#1486` merge, and the minimum plumbing is +9 lines
  with no comment. Captured as `3IYCQxfH` (`_perf/gate.tl` reaches 490/500
  with three open items wanting to edit it). No `block` edge is filed,
  because the split alone does not make this specifiable — the soundness
  question above does.
