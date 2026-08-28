## Evidence

D34 (PR #1483, item `3IVL9t0P`) re-keys the perf gate's strike-twice rule
to the re-measured baseline. Its **third rejected option** — "also give the
baseline PAIR its own noise credit" — is recorded as *correct, and better;
rejected here as a separate slice rather than forever*, but no board item
carries that slice. `gitboard find` over `loudest_control`, `triage_many`,
`baseline` and `control` returns nothing matching it, so the deferral has
no home and the record points at work nobody is tracking.

The mechanism, as D34 states it: `opts.baseline` and `base_side` measure the
SAME binary by construction — `gate_inner` refuses the retry outright when
they do not (`_perf/gate.tl`, the `identity_refusal(opts.baseline, base_side,
true)` check) — so their disagreement is a legitimate A/A control. Reading it
would absorb, at its source, the false red D34 knowingly accepts and pins in
`_perf/gate_strike_test.tl:test_a_one_off_fast_baseline_retry_fails_the_gate`.

Why it is not a one-liner: `_perf/compare.tl`'s `loudest_control` is not
exported, and appending the two baseline runs to the existing `controls` list
would form baseline-versus-current pairs — the comparison under test — so it
needs `triage_many` to take a second control GROUP. That is inside the module
D34 deliberately does not touch, and D31
(`docs/decisions/d31-gate-noise-from-every-control-pair.md`) governs it.

## The exposure this leaves open

The residue D34 names is per-scenario: a scenario quiet across all three
current-side control pairs whose two baseline readings disagree past the bar
now fails where it used to pass. The same mechanism at SUITE scale is the
sharper case and is not named anywhere: a uniform level shift between the two
baseline runs (the runner's clock/thermal state moving mid-job) shifts every
scenario in `base_side` together, so `compare_once(base_side, opts.current)`
and `compare_once(base_side, retry)` flag the same broad set while every
control pair — all current-binary — stays quiet, and nothing credits it.
Item `3IU0GxoA` measured level moves of 20-33% on a byte-identical binary
between sessions, well past the 10% bar; the same effect inside one job
would read as a broad red.

The direction is a false RED, not a false green, and `release.yml` already
prints the remedy (re-run the workflow), which is why D34 accepts it. The
baseline-pair credit is the instrument that removes it.

## Not yet refined

This is a capture, not a ready slice. What a refinement must settle: the
shape of a second control group in `triage_many`, whether `loudest_control`
becomes exported or the grouping stays inside `compare.tl`, and whether D31
is amended or a new record is earned. D34's "what would make us revisit"
condition — repeated release reds traceable to the baseline retry rather
than to the change under test — is the trigger to promote it.
