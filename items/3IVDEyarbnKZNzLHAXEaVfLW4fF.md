## Problem

A real code delta on `codec_base64_roundtrip_64k` measures roughly
twice as large when the session lands on the fast level as when it
lands on the slow one. 3IU0GxoA established this from two correctly
interleaved same-session experiments, both REPRODUCED: the same code
delta read **+9.44%** at the ~191 µs level (3ISlWFiS) and **+20.16%**
at the ~144 µs level (3ITOUv0w). The level a session lands on is not
observable from inside the container, and the same byte-identical
binary has been recorded at both (cosmic `d8492168…`: median 191.31 µs
in one session, 144.29 µs in another, disjoint ranges, +32.6%).

So the fixed-percentage bar in `_perf/compare.tl`
(`DEFAULT_THRESHOLD_PCT = 10.0`, and `noise_pct = max(threshold,
baseline spread, current spread)`) has about 2x different sensitivity
depending on which level the session landed on, even when it is
applied to a correctly interleaved pair. A regression that clears the
bar at the fast level can sit under it at the slow one.

Open question, not a finding: whether anything should change. Three
shapes worth weighing, none of them chosen:

- a bar expressed relative to the session's own measured level, or a
  normalisation of the delta by it;
- a per-scenario floor derived from accumulated same-binary A/A
  selfcheck spreads (the selfcheck pair is same-binary AND
  same-session by construction) — note the evidence says same-session
  spread is TIGHT (CV 1.2-5.3% across every labeled group on record),
  so a history-derived floor would likely come out SMALL;
- nothing: record the effect in `skills/optimize/measurement.md` and
  leave the arithmetic alone.

The first job of any slice cut from this is to answer the question
from data the gate already writes, not to implement a derivation on
the assumption that one is needed.

## The wall this inherits

3IU0GxoA's "What this does NOT license" binds here. The 20-33%
cross-session spread is NOT a noise budget for the release lane: that
lane measures baseline and candidate in the SAME job on the SAME
runner (`release.yml` downloads the previous release's binary and runs
it beside the candidate), which is the interleaved shape the
cross-session effect cannot reach. 3ISlY5Xl used this scenario's
within-session tightness to hold a release at +21.0% via
`21.0 > max(10.0, 2 x 4.8)`; widening the floor would retire the
arithmetic that kept that gate honest over a regression two
independent interleaved experiments have since confirmed. Whatever
this item concludes, no committed threshold for
`codec_base64_roundtrip_64k` may end larger than it starts
(`DEFAULT_THRESHOLD_PCT = 10.0`, `TRIAGE_K = 2.0`, measured
2026-08-27 at origin/main `267c2a4d`).

## Relation to 3IUBNQZZ

3IUBNQZZ carries the founded, implementable half of the same evidence
base — stamping each side's binary identity and measurement time into
every table the perf gate prints — and names this item in its
Non-goals. This item is the unfounded half, deliberately left in the
backlog until someone is ready to answer its question from recorded
selfcheck data rather than from the hypothesis in its title.
