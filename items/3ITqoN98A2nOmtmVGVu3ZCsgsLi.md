Evidence, from reviewing PR #1426 (item 3ITnbooy, cosmos pin bump) on
2026-08-27.

The compare gate's escalation (`_perf/gate.tl:117-190`) filters noise
by re-measuring the CURRENT binary — a retry run, then an A/A
self-check, then `compare.triage_many` over three control pairs. Every
one of those controls is measured in the run's own machine window. The
BASELINE is not re-measured and its age is never checked: the only
thing `identity_refusal` (`_perf/gate.tl:88-97`) asserts about the pair
is which binary each names.

So a baseline measured in an earlier, faster machine window produces a
regression the gate cannot triage away, however many controls it runs
— the drift lives in the file the gate never re-measures. That is what
#1426 hit: the gate flagged `fs_walk_tree +25.6%` through its final
pass, while an interleaved same-window 3x3 A/B of the two runtimes
(old 353.7/347.2/354.5 us, new 364.6/362.0/357.5 us) put the same
scenario at +2.3% at medians, inside its ~11% per-run noise. The gate
was measuring the clock, not the change.

The cost is not a false alarm; it is what the false alarm makes a
builder do. The gate's verdict line is what specs put in `Acceptance`,
so an unreachable PASS pushes the builder into hand-triage in the PR
body — exactly the "absorb it rather than raise it" move the same
specs forbid in `Non-goals`.

Candidate countermeasures, cheapest first, for refinement to pick
between: have `compare` refuse or loudly warn when the baseline's
measurement is not from the current window (the results format would
need to carry a stamp it can be judged by); or re-measure the baseline
binary as part of the escalation, so the controls cover both sides;
or, docs-only, make "baseline in the same window, immediately before
the comparison" an explicit precondition in `skills/optimize/` and in
the gate's own doc comment, so a stale baseline is a builder error
with a name rather than a surprise.
