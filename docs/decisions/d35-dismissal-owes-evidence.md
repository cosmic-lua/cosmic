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
  - **what actually changes**, measured by sweeping the (f, r) plane
    through `compare.diff` and `reproduce.restore`. Two things make the
    region wider and stranger than the arithmetic suggests. The control
    pair does not read the difference `f - r`: it reads the RATIO
    `c = (r - f) / (1 + f)`, whose denominator is the loud pass-1
    sample. And `compare.loudest_control` records a control only when
    that control's own verdict is `regression` or `faster`, so a
    control pair UNDER the noise bar buys no credit at all rather than
    `2|c|` — it is treated exactly like no control. The rule is
    therefore `restore iff |c| <= N or f > 2|c|`: it absorbs on
    `[L(r), U(r)]` and fires everywhere else above `N`, with

    ```text
    L(r) = max((N + r) / (1 - N), (1 - sqrt(1 - 8r)) / 2)
    U(r) = (1 + sqrt(1 - 8r)) / 2          (r and N as fractions)
    ```

    Bisected on the real code at `N = 10`, and matching that form to
    four decimals:

    | retry `r` | absorbed band `[L(r), U(r)]` |
    |---|---|
    | 0.0% | [11.1111%, 100.0000%] |
    | 2.5% | [13.8889%, 94.7214%] |
    | 5.0% | [16.6667%, 88.7298%] |
    | 7.5% | [19.4444%, 81.6228%] |
    | 9.0% | [23.5425%, 76.4575%] |
    | 10.0% | [27.6393%, 72.3607%] |

    Two consequences follow, and neither is what "the loud kind is
    absorbed" would predict. **The firing region is not an interval; it
    has an unbounded upper arm.** `|c|` is a ratio and cannot exceed
    100%, so `2|c| < 200%` always and `U(r) <= 100%`: a pass-1 flag
    past +100% is restored however quiet the retry, and so is the loud
    kind well below that — `f = 75%` with `r = 10%` restores. **And the
    rule is non-monotone in `r`.** The absorbed band is WIDEST when the
    retry returns ALL the way to baseline, because a control pair that
    swings hard buys the most credit: `f = 15%` with `r = 0%` is
    absorbed, while the same flag with the WEAKER refutation `r = 5%`
    is restored. `_perf/reproduce_test.tl` pins every edge above, so
    this record cannot drift from the code.
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
  The cost is a new false-red class, and it is not narrow: the region
  measured above is `(N, L(r))` plus an unbounded arm above `U(r)`, so
  a loud non-reproducing dismissal is restored as readily as a
  straddling one, and a retry that refutes the flag completely is
  absorbed where a partial refutation is not. What keeps that
  affordable is that the restoration ESCALATES rather than failing
  outright, so the third sample and the fuller control set get their
  say first —
  `test_a_third_sample_absorbs_an_unexplained_dismissal` shows a
  restored flag being credited and passing. A dismissal across two
  different binaries is left alone entirely
  (`test_a_dismissal_with_no_same_binary_pair_stands`). The remedy for a
  false red is the one `release.yml` already prints: re-run, because a
  real regression reproduces and noise does not. What would make us
  revisit: restored flags that the third sample keeps absorbing, which
  would say the region is credited noise rather than a straddling
  regression — and the fix then is the baseline-pair credit above, or
  giving an under-bar control pair its own credit, not a wider bar.
