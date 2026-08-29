# D36 — a disagreeing baseline pair earns a third reading and is judged by the median

- **date:** 2026-08
- **status:** active
- **context:**
  [D34](d34-reproduction-against-remeasured-baseline.md) gave the perf
  gate's two current-side samples ONE common baseline: `gate_inner`
  re-measures the baseline binary between the passes and judges passes 2
  and 3 against that reading. The gate therefore holds two readings of
  the same binary — the caller's `baseline` file and the
  `--baseline-bin` retry, refused outright when they name different
  binaries — and nothing decides which of them is the outlier when they
  disagree past the bar. D34 took the retry, named the false red that
  costs, and deferred the disagreement to a later slice: "also give the
  baseline PAIR its own noise credit", recorded there as *correct, and
  better*. [D35](d35-dismissal-owes-evidence.md) repeats that referral
  in its own rejected list.

  That instrument cannot work, and neither can any other function of the
  two readings. Both facts were measured against `origin/main` at
  `9048f3b6`.

  **The linear credit is contradictory.** Feed each of D34's two pinned
  fixtures' baseline pairs in as a control group and read `triage_many`'s
  rule `|reg| <= max(noise_pct, TRIAGE_K * |control|)`, in
  `loudest_control`'s own pair orientation `diff(controls[i],
  controls[j])`:

  ```text
  false-red   reg=+42.8571%  ctrl=-30.0000%  |reg|/|ctrl|=1.4286  K=2.0 credits? true
  masked-reg  reg=+30.0000%  ctrl=-23.0769%  |reg|/|ctrl|=1.3000  K=2.0 credits? true
  TRIAGE_K = 2.0
  ```

  The first row is `test_a_one_off_fast_baseline_retry_fails_the_gate`,
  the false red D34 knowingly accepted; the second is
  `test_masked_baseline_regression_still_fails`, the regression D34
  landed to unmask. At `TRIAGE_K = 2` the rule credits BOTH, so
  `gate_inner` returns 0 and D34's decision is undone. Crediting the
  first needs `K >= 1.4286`; denying the second needs `K < 1.3000`. The
  interval is empty, and the ordering runs backwards — tightening `K`
  denies the false red before it denies the masked regression.

  **No formula over the pair separates them, because the two cases can
  be made the SAME measurement.** Both fixtures have the shape "current
  side steady and equal to the pass-1 baseline reading; the baseline
  retry the sole dissenter", so the gate's whole input reduces to two
  readings of the baseline binary against a current side that agrees
  with one of them by construction. Driven end to end through
  `gate.gate` on byte-identical inputs — driver `a` 1000 -> 1300 to
  reach the retry path, scenario `x` reading baseline 1000, baseline
  retry 700 and both current-side runs 1000, differing ONLY in a third
  baseline reading the gate did not yet take:

  ```text
  before this change: third=1000 -> 1   third=700 -> 1
  after  this change: third=1000 -> 0   third=700 -> 1
  ```

  `third=1000` is the false red — the 700 was the one-off, nothing
  regressed, the gate must pass. `third=700` is a real +42.9%
  regression that a one-off SLOW pass-1 baseline reading of 1000 masked,
  and the gate must fail. Same two readings, same current side, opposite
  correct verdicts. Deciding between them is exactly deciding which
  baseline reading was the outlier, and that fact is not in the pair. A
  third reading is not one instrument among several; it is the only one.
- **decision:** on the `--baseline-bin` path, the baseline side is the
  MAJORITY of the readings, not the latest of them. `_perf/tiebreak.tl`
  owns the question:
  - the baseline binary is re-measured once into `baseline`'s own
    `-retry.json` sibling, as before, and held to the same identity rule
    (`compare.identity_refusal(..., same = true)`);
  - when that reading agrees with the caller's everywhere under the bar
    — no scenario reading `regression` or `faster` — the retry IS the
    baseline side, exactly as it was, and **no third pass is measured**;
  - when they disagree on any scenario, the binary is measured a THIRD
    time into `-retry2.json`, refused under the same identity rule, and
    the per-scenario median of the three readings is written to
    `-median.json` and judged against by passes 2 and 3.

  Median of three is "the majority says which reading was the outlier",
  which is the only discriminator the measurement above leaves standing.
  The median is a tiebreak over comparable numbers, not a way to invent
  one: a scenario not present with a `wall_ns` and no `error` in every
  reading keeps the first reading's row verbatim.

  Everything else is untouched. D34's re-key of `flagged_first` to
  whatever the baseline side ends up being stands, and so does
  [D35](d35-dismissal-owes-evidence.md)'s rule that a dismissed
  regression owes the same evidence a credited one does.
  [D31](d31-gate-noise-from-every-control-pair.md) governs how much
  variance a scenario is credited for and stands unamended, because this
  change creates no credit at all: `TRIAGE_K`, the 10% bar and the
  verdict vocabulary do not move, and no baseline-versus-current pair is
  formed as a control anywhere.
- **rejected:**
  - **give the baseline PAIR its own noise credit** — D34's third
    rejected option, referred forward twice as the instrument that would
    fix the false red properly. Disproved by the first measurement
    above: at `TRIAGE_K = 2` it credits the masked regression too and
    undoes D34, and no value of `K` credits one without the other
    because the required interval `[1.4286, 1.3000)` is empty. The
    suite-scale concern that motivated it — a level shift moving the
    whole baseline — survives; its instrument does not.
  - **spend the pair as a `noise_pct` widening** (bar = `max(10,
    |control|)` for the flagged scenario). Sound and useless: `42.86 >
    30` keeps the false red and `30 > 23.08` keeps D34 intact, so it
    denies both cases and changes nothing.
  - **a non-linear credit with a knee between the two control swings.**
    Arithmetically possible — any knee inside `(23.08%, 30%]` credits
    the false red and denies the masked regression — and rejected
    because it asserts that a 30% baseline swing is noise while a 23%
    one is real, which is not a fact about anything. The second
    measurement is the harder refusal: once the two cases are put on
    identical numbers the knee has nothing left to key on.
  - **always take three baseline readings.** Costs the third pass on
    every gate run that reaches the retry, including the runs whose pair
    agrees and where the median cannot change the verdict. The
    conditional is a strict saving with no behaviour difference, so
    there is nothing to buy.
  - **do nothing and let D34's false red stand.** D34 named its own
    revisit trigger as repeated reds traceable to the baseline retry,
    and on the false red alone this would be premature. It is not the
    whole case: the same disagreeing pair is what a suite-wide level
    shift produces, and the only remaining instrument for that was the
    baseline-pair credit disproved above. Buying the third reading
    closes both, and nothing else does.
- **consequences:** the false red D34 accepted is gone — the gate now
  answers 0 where it answered 1, on the same inputs, and the masked
  regression D34 landed to unmask still answers 1. D34's consequences
  name `test_a_one_off_fast_baseline_retry_fails_the_gate` as the
  fixture that pins the accepted cost; that fixture is renamed
  `test_a_one_off_fast_baseline_retry_is_outvoted` and now asserts the
  opposite verdict, which is the mutation test for this change.

  The cost is one extra measurement pass, and only on a gate run whose
  two baseline readings actually disagree — a run that has already
  flagged a regression. On the clean path there is none: `gate_inner`
  returns before the retry when pass 1 flags nothing, so a normal
  release measures exactly what it measures today. One full measurement
  pass took 65 s in a development container; `release.yml`'s "compare
  against the previous release" step, the one caller of
  `--baseline-bin`, carries `timeout-minutes: 15`.

  What this does NOT fix, stated so nobody reads it as more than it is:
  a majority of three is only as good as the assumption that at most one
  reading is an outlier. When TWO of the three readings are outliers
  together — a suite-wide level shift lasting two of the three passes —
  the median follows them and the gate is wrong in the same direction it
  was before. Measured on the same harness: with nothing regressed and
  both re-measurements reading 30% fast, the gate returns 1. What would
  make us revisit: reds traceable to a level shift that spans two
  baseline readings rather than one.

  One behaviour change rides along, deliberately. A failed baseline
  re-measurement now exits 1 with a printed message instead of
  propagating the runner's own exit code; `release.yml` branches on
  nonzero, so it is unobservable at the one caller, and
  `test_a_failed_measurement_is_reported` pins it. The CURRENT-side
  measure's exit code still propagates unchanged.
