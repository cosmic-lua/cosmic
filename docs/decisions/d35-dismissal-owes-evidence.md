# D35 — a dismissed perf regression owes the same evidence a credited one does

- **date:** 2026-08
- **status:** active
- **context:** `_perf/gate.tl`'s compare gate fails a regression only
  when two independent current-side samples flag it
  ([D34](d34-reproduction-against-remeasured-baseline.md)). The two ways
  those samples can disagree were not treated alike. A regression
  standing in pass 2 that pass 1 did not flag reclassifies to `noise` at
  the final judgment, after a third sample and magnitude-aware triage
  across three control pairs. A regression pass 1 DID flag that pass 2
  reads quiet ended the gate on the spot — `gate_inner` returned 0 the
  moment pass 2's failure count reached zero — dismissed on two samples,
  with no control consulted and no message printed. The dismissal is the
  cheaper judgment of the two, and it is the one that publishes.

  What that admits is not an exotic case. With a noise bar `N`, a pass-1
  delta `f > N` and a pass-2 delta `r <= N`, the two current-side
  samples straddle the bar whenever `r` is just under it and `f` just
  over. Reproduced end to end through `gate.gate` on
  `origin/main@29011923`, one scenario reading 1.00 µs baseline, 1.12 µs
  in pass 1 and 1.09 µs on the retry, both current-side files naming the
  same `bin_sha`:

  ```text
  a                                 1.00 µs ->      1.12 µs    +12.0%  (noise  ±10.0%)  regression
  perf-compare: regression flagged; re-measuring once into .../cur-retry.json to filter noise
  a                                 1.00 µs ->      1.09 µs     +9.0%  (noise  ±10.0%)  ok
  1 scenarios: 0 regression, 0 faster, 1 ok, ...
  perf-compare: PASS
  ```

  Both samples say the scenario is up by roughly a tenth. One fell under
  the bar, and that alone published the release. `release.yml`
  re-baselines to the PREVIOUS RELEASE's binary daily, so the escape is
  absorbed into tomorrow's baseline and nothing ever asks about it again
  — the same ratchet D34 weighed.
- **decision:** a dismissal is credible only when the same-binary
  controls explain it. A regression pass 1 flagged that pass 2's table
  does not carry as a regression keeps its dismissal only when the
  controls show that scenario swinging by enough to account for the two
  samples disagreeing — the credit rule `triage_many` already applies,
  `|pass-1 delta| <= max(pass-1 noise bar, TRIAGE_K * |loudest control
  delta|)`. An unexplained dismissal has its verdict amended back to
  `regression`, its reason printed as a `perf-compare:` line, and,
  because the amendment happens before the report and before the clean
  exit, escalates to the A/A self-check and full triage like any other
  persisting regression.
  - **the controls are the samples already on disk.** The gate holds the
    caller's `current` file and the retry by the time it asks, so the
    A/A control the dismissal never had was there all along, unread —
    it is the disagreement itself. The rule costs no measurement pass on
    the clean path and takes a third sample only after a dismissal is
    already unexplained.
  - **only a same-binary pair may be asked.** The rule is gated on
    `same_binary(opts.current, retry)`. Two current-side samples are
    comparable to each other on no other terms, and a stampless pair
    names no binary, so it turns the rule off rather than on.
  - **the rule reaches only current-side pairs.** No
    baseline-versus-current pair — the comparison under test — is ever
    formed as a control, which is what keeps this separate from the
    baseline-pair credit D34 rejected as its own slice.
  - **what actually changes**, in closed form: with the control pair
    reading roughly `f - r`, a dismissal is unexplained exactly when
    `f > max(N, 2 * (f - r))`, i.e. `N < f < 2r`. At `N = 10` that is a
    pass-1 delta in (10, 20) with a retry in (5, 10]. Every other
    dismissal — the loud, genuinely non-reproducing kind — is absorbed
    exactly as before.
- **rejected:**
  - **take a third current-side sample whenever pass 2 reads quiet.**
    The straightforward answer, and it buys a real extra measurement
    where this one reads a free one. It loses twice. It costs a full
    measurement pass inside a release step already carrying
    `timeout-minutes: 15`, on the path that is quiet — which is most
    runs. And it leaves the decision rule open: the obvious 2-of-3
    majority reclassifies `b` in
    `_perf/gate_strike_test.tl:test_strike_once_regression_reclassifies_and_passes`,
    where the self-check repeats the retry's numbers and `b` therefore
    flags in two of three, reinstating exactly the false red that test
    pins.
  - **read the A/A control unconditionally and triage BOTH passes,
    failing on either.** That is the union rule — D34's second rejected
    option under another name — and the same
    `test_strike_once_regression_reclassifies_and_passes` refuses it: a
    scenario flagging only in the retry because the current side moved
    would fail the gate again.
  - **give the BASELINE pair its own noise credit instead.** D34's third
    rejected option, and still the instrument that fixes the false red
    D34 accepted. It is a different defect from this one — it credits a
    scenario the gate flags, where this demands evidence for one the
    gate waves through — and it needs `triage_many` to take a second
    control GROUP, since the baseline runs cannot join the existing
    `controls` list without forming baseline-versus-current pairs. It
    remains its own slice. This change exports `compare.loudest_control`,
    which that slice also needs.
- **consequences:** the two current-side samples now have to agree
  before the gate publishes, so a regression that reads +12% then +9%
  fails instead of shipping, and the reason is printed rather than
  inferred. `test_two_agreeing_samples_straddling_the_bar_fail` pins it.
  The cost is a new false-red class, and it is narrow by construction:
  only a scenario whose pass-1 delta lands in `(N, 2r)` with quiet
  controls can be restored, and the restoration escalates rather than
  failing outright, so the third sample and the fuller control set get
  their say first —
  `test_a_third_sample_absorbs_an_unexplained_dismissal` shows a
  restored flag being credited and passing. A dismissal across two
  different binaries is left alone entirely
  (`test_a_dismissal_with_no_same_binary_pair_stands`). The remedy for a
  false red is the one `release.yml` already prints: re-run, because a
  real regression reproduces and noise does not. What would make us
  revisit: restored flags that the third sample keeps absorbing, which
  would say the band is credited noise rather than a straddling
  regression — and the fix then is the baseline-pair credit above, not a
  wider bar.
