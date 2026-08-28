## Evidence

`gate_inner` measures the baseline side twice: `opts.baseline` and the
retry `base_side`. When those two disagree, nothing decides which is
right, because two readings have no majority. D34 chose to judge
reproduction against the re-measured one (`b0aeb1dd`), which is correct
for the case it settled and leaves the disagreement itself unresolved.

Spending that pair as a noise control instead does not work, and the
arithmetic is closed rather than tunable. Over the two fixtures D34
pinned in `_perf/gate_strike_test.tl`, a false red and a masked-baseline
regression are the SAME measurement — steady current side, disagreeing
baseline pair, baseline retry faster. Under `triage_many`'s
`|reg| <= max(10, TRIAGE_K * |control|)`:

- `:169` (the false red, credit intended): `42.86 <= max(10, 60)` — credited.
- `:144` (`test_masked_baseline_regression_still_fails`): `30.00 <= max(10, 46.15)`
  — also credited, so `gate_inner` returns 0 and D34's decision is undone.

No constant escapes it: crediting the first needs `K >= 1.4286`, denying
the second needs `K < 1.3000`. Spending the pair as a `noise_pct`
widening preserves D34 but does not fix the false red.

A third baseline sample is the only discriminator that separates them —
a majority of readings decides which baseline is the outlier, which both
credits the false red and keeps the masked regression failing. That is a
measurement-budget change, not a formula change, which is why it is its
own item rather than a variant of `3IWx3I4Z`.

This derivation is arithmetic over the fixtures' literal numbers and
`triage_many`'s formula; it was not executed. Confirm by reading
`_perf/gate_strike_test.tl:144,169` and `_perf/compare.tl`'s
`triage_many` before building.

## Cost, unmeasured

A third baseline measurement pass costs release-lane wall time that has
not been measured. Whether it is affordable, and whether it runs always
or only when the pair disagrees, is the open question this item must
settle before it can carry a `## Change`.
