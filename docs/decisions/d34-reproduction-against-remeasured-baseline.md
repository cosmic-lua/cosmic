# D34 — the perf gate judges reproduction against the re-measured baseline

- **date:** 2026-08
- **status:** superseded by D36
- **context:** `release.yml`'s perf gate fails a regression only when it
  strikes TWICE — the strike-twice rule, added because a scenario
  flagging in one pass and quiet in the next did not reproduce and is
  variance, not a regression. `_perf/gate.tl`'s `gate_inner` implemented
  the rule by comparing two flag SETS: `flagged_first`, built from pass
  1's deltas against the caller's `baseline` file, against the flags
  standing after pass 2. When the caller can re-run the baseline binary
  (`--baseline-bin`, whose one caller is
  `.github/workflows/release.yml`'s perf-compare step), the gate
  re-measures the baseline between those two passes and judges passes 2
  and 3 against the RE-MEASURED file. So the rule asked whether a
  regression reproduced against a moving reference, and a scenario whose
  pass-1 baseline reading was one-off SLOW — which masks the regression
  there — flags for the first time in pass 2 against the honest retry,
  survives triage with quiet controls, and is then discarded at the
  final judgment as "flagged only in the retry -- not reproduced".
  Reproduced end to end through `gate.gate` at `origin/main@6a4d0182`,
  base `{a=1000, b=1300}` against current `{a=1300, b=1300}` with the
  baseline retry reading `{a=1000, b=1000}`:

  ```text
  b                                 1.00 µs ->      1.30 µs    +30.0%  (noise  ±10.0%)  regression
  perf-compare: regression persists; running A/A self-check to separate real regressions from machine noise
  perf-compare: b flagged only in the retry -- not reproduced, counted as noise
  b                                 1.00 µs ->      1.30 µs    +30.0%  (noise  ±10.0%)  noise
  2 scenarios: 0 regression, 0 faster, 1 ok, 1 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0 malformed
  perf-compare: PASS
  ```

  Two facts make that escape expensive rather than merely wrong. A
  one-off per-scenario reading is ROUTINE on either side, so a masked
  baseline is not an exotic case: `gate.tl selfcheck A.json B.json` over
  the full suite — the same binary measured twice, back to back, in one
  container, on 2026-08 — reported `48 scenarios: 12 regression, 1
  faster, 35 ok, 0 noise, 0 new, 0 missing, 0 error, 0 baseline-error, 0
  malformed`. Thirteen of forty-eight scenarios cross the 10% bar
  against THEMSELVES, up to +95.1% (`sqlite_point_query`), +33.1%
  (`stream_lines_iterate`) and +31.0% (`re_match_log_line`). And
  `release.yml` re-baselines to the PREVIOUS RELEASE's binary daily, so
  a regression published once is absorbed into tomorrow's baseline and
  the gate never asks about it again.
- **decision:** the reproduction rule reads ONE baseline — the
  re-measured one — and asks two INDEPENDENT current-side samples about
  it. After the baseline retry and its identity check, `gate_inner`
  recomputes `flagged_first` from `compare_once(base_side,
  opts.current, opts.threshold)`: the caller's own pass-1 current file,
  judged against the re-measured baseline. Both files are already on
  disk, so this costs no measurement. The recomputation is guarded on
  `base_side ~= opts.baseline`, so an invocation without
  `--baseline-bin` never enters it and its behaviour is unchanged.
  `TRIAGE_K` and the default 10% bar are untouched;
  [D31](d31-gate-noise-from-every-control-pair.md) governs how much
  variance a scenario is credited for and stands unamended. This
  decision is only about WHICH baseline the reproduction question is
  asked against.
- **rejected:**
  - **keep pass 1's flags as measured.** The option a competent
    contributor would defend: requiring the flag against BOTH baseline
    readings suppresses strictly more noise, and a false red is the
    failure `skills/optimize/measurement.md` spends a whole chapter
    teaching people to avoid. It loses because the two errors are not
    symmetric in cost. A false red costs one workflow re-run, and the
    workflow's own failure message already says to take it. The false
    green it buys is a regression published into the release whose
    binary becomes tomorrow's baseline — absorbed into the ratchet
    permanently, and never re-asked by anything.
  - **count a regression flagging in EITHER pass (the union).** The
    cheapest way to close the escape, and it reinstates exactly the
    false red the strike-twice rule exists to remove: a scenario
    flagging only in the retry because the CURRENT side moved, which
    `test_strike_once_regression_reclassifies_and_passes` pins and
    which held three daily releases in a row before the rule landed.
  - **also give the baseline PAIR its own noise credit.**
    `opts.baseline` and `base_side` measure the same binary by
    construction — `gate_inner` refuses the retry outright when they do
    not — so their disagreement is a legitimate A/A control, and
    reading it would absorb the false red this change accepts, directly
    and at its source. Correct, and better; rejected here as a separate
    slice rather than forever. `_perf/compare.tl`'s `loudest_control`
    is not exported, and adding the two baseline runs to the existing
    `controls` list would form baseline-versus-current pairs — the very
    comparison under test — so it needs `triage_many` to take a second
    control GROUP, which is a change to the module this decision
    deliberately does not touch. The measured reason it can wait: a
    scenario unstable enough to produce a one-off baseline reading is
    normally unstable on the current side too, where D31's credit
    already absorbs it, which is what
    `test_current_side_instability_absorbs_the_fast_baseline_retry`
    shows.
- **consequences:** a regression the pass-1 baseline masked now fails
  the gate instead of shipping, which is the point. The cost is paid in
  the other direction and is real: a scenario quiet across all three
  current-side control pairs whose TWO BASELINE readings disagree past
  the bar now fails where it used to pass, because both current samples
  flag against the faster of them and nothing credits the baseline's own
  spread. `test_a_one_off_fast_baseline_retry_fails_the_gate` pins that
  cost rather than hiding it. The remedy is the one `release.yml`
  already prints — re-run the workflow, because a real regression
  reproduces and noise does not — and the daily cron means a re-run
  costs a day at worst, against a false green that costs the ratchet.
  What would make us revisit: repeated reds traceable to the baseline
  retry rather than to the change under test. Then buy the baseline-pair
  credit above, which is the instrument that fixes the cost properly.
  What this does NOT fix, stated so nobody reads it as more than it is:
  the sampling stays asymmetric. A regression reading quiet on the retry
  still ends the gate on two current-side samples with no A/A control at
  all, while one flagging twice earns a third sample and triage across
  three control pairs.

- **amended 2026-08 (D35 closed the dismissal asymmetry):** the
  asymmetry named in the closing paragraph above is no longer left
  open. A regression pass 1 flagged that pass 2 reads quiet no longer
  ends the gate on the spot: it must be explained by the same-binary
  controls the gate already holds, or its verdict is amended back to
  `regression` and it escalates to the third sample and full triage
  like any other persisting one.
  [D35](d35-dismissal-owes-evidence.md) records that tradeoff, including
  the measured region the restore fires in. What this record decided —
  that reproduction is judged against the RE-MEASURED baseline, with
  pass 1's flags re-keyed to it — is unchanged, and so are its three
  rejected options; D35 sits beside it rather than over it.
