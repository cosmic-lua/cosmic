## Capture

D36 (#1498) buys a third baseline reading and judges against the
median when the two readings disagree past the bar. Its consequences
name one residue — "when TWO of the three readings are outliers
together ... the median follows them" — and present that as the whole
of what the change does not fix. Measured in review, it is not: a
SINGLE one-off baseline reading that lands UNDER the pair bar is never
outvoted either, because the tiebreak's trigger and the gate's
judgment measure the same gap against different denominators.

`_perf/tiebreak.tl:disagrees` asks `compare.diff(base, retry,
threshold)`, whose `delta_pct` is `(retry - base) / base`. The later
judgment asks `compare_once(base_side, current, threshold)`, whose
`delta_pct` is `(cur - base_side) / base_side`. With `base_side =
retry`, the same absolute gap reads `d` as a disagreement and
`d / (1 - d)` as a regression. For the default 10% bar that leaves a
band where the pair is declared to agree — no third reading bought —
and the gate still answers on the outlier alone.

## Evidence (measured 2026-08-29 on PR #1498 head `086f8793`, `_probe/` scripts, since removed)

Both probes drive `gate.gate` end to end with an injected `measure_baseline`
whose FIRST call is the one-off; a third reading, when bought, agrees
with the caller's baseline. Driver `a` 1000 -> 1300 reaches the retry path.
`spread_pct` is 0 everywhere, so the bar is the plain 10%.

**False-red direction** (baseline x = 1000, current x = 1000 in every
run — nothing regressed):

```text
  retry x= 940  pair delta= -6.000%  regression would read= +6.383%  -> code=0  baseline_measures=1
  retry x= 905  pair delta= -9.500%  regression would read=+10.497%  -> code=1  baseline_measures=1
  retry x= 900  pair delta=-10.000%  regression would read=+11.111%  -> code=1  baseline_measures=1
  retry x= 890  pair delta=-11.000%  regression would read=+12.360%  -> code=0  baseline_measures=2
  retry x= 700  pair delta=-30.000%  regression would read=+42.857%  -> code=0  baseline_measures=2
```

A one-off fast retry in roughly `[-10%, -9.09%)` is called agreement,
buys no third reading, and fails the gate on nothing.

**Masking direction** (honest baseline x = 1000, a real +15% regression
at current x = 1150):

```text
  one-off SLOW retry x=1000  pair delta= +0.00%  -> code=1  baseline_measures=1  (caught)
  one-off SLOW retry x=1050  pair delta= +5.00%  -> code=0  baseline_measures=1  (MASKED)
  one-off SLOW retry x=1095  pair delta= +9.50%  -> code=0  baseline_measures=1  (MASKED)
  one-off SLOW retry x=1099  pair delta= +9.90%  -> code=0  baseline_measures=1  (MASKED)
  one-off SLOW retry x=1101  pair delta=+10.10%  -> code=1  baseline_measures=2  (caught)
  one-off SLOW retry x=1150  pair delta=+15.00%  -> code=1  baseline_measures=2  (caught)
```

Any one-off slow retry in `(0, +10%]` still masks a real regression of
any size.

**This is a strict improvement, not a regression.** The same two probes
on `origin/main@9048f3b6` (gate reverted, `_perf/tiebreak.tl` removed):

```text
  false red:  every fast retry past the bar -> code=1  (940 -> 0; 905, 900, 890, 700 -> 1)
  masking:    1050, 1095, 1099, 1101, 1150  -> code=0  (all MASKED)
```

So #1498 shrinks the masking region from unbounded to `(0, +10%]` and
the false-red region from `(bar, infinity)` to a ~1 percentage-point
sliver. Nothing here argues against that change; the gap is what is
left, and D36 does not name it.

## Why this is worth an item

D36's "What this does NOT fix, stated so nobody reads it as more than
it is" is the paragraph a later session will read to decide whether the
baseline side is settled. As written it says the assumption is "at most
one reading is an outlier", which a reader will take to mean a single
outlier is always corrected. Measured, a single outlier under the pair
bar is not. Two things follow, and they are separable:

1. **The record owes an amendment** naming the sub-bar residue and both
   its directions, with these numbers.
2. **The mechanism may owe a fix.** Candidates, none evaluated here:
   ask `disagrees` in the orientation the judgment will use
   (`diff(retry, base)`), so the two questions share a denominator; or
   drop the bar for the pair test and buy the third reading on any
   non-zero disagreement, paying the pass more often. The cost
   discipline D36 sets — a third pass only inside a narrow condition on
   a run that already flagged — is what any candidate has to hold to.

Refinement should decide whether 1 alone is enough. The masking
direction is the expensive error, and `(0, +10%]` is not a corner of
the parameter space: it is every baseline reading that moved less than
the bar, which is most of them.

## Enablement

Nothing. `_perf/gate_strike_test.tl` and `_perf/tiebreak_test.tl` are
the fixtures a fix would extend, and both probes above are ~50 lines of
Teal against the shipped `gate.gate` API.
