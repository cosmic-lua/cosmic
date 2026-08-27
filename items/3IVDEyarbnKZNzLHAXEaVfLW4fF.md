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

Open question, not a finding: whether anything should change.

## The data source this needs does not exist yet

Recorded by 3IUBNQZZ's bounce (2026-08-27, session 0b13d2b4) and load
bearing for any slice cut from here: **the gate persists no A/A
history.** `_perf/gate.tl`'s `selfcheck` takes `A.json B.json`,
measures into both paths the caller named, compares, and returns —
nothing accumulates — and `o/perf/*.json` is never committed
(AGENTS.md). There is no accumulated cross-window A/A history anywhere
in the tree from which a per-scenario floor could be derived. So the
phrase "derive it from the selfcheck files the gate already writes" is
false as stated, and the first decision here is whether a history
store should exist at all, where it lives, who writes it, and what
reads it. That is a decision nobody has taken, which is why this item
is in the backlog rather than in plan.

## Shapes worth weighing, none of them chosen

- a bar expressed relative to the session's own measured level, or a
  normalisation of the delta by it — needs no history store, which is
  the cheapest reason to weigh it first;
- a per-scenario floor derived from accumulated same-binary A/A
  spreads (a selfcheck pair is same-binary AND same-session by
  construction) — needs the store above, and note the evidence says
  same-session spread is TIGHT (CV 1.2-5.3% across every labeled group
  on record), so a history-derived floor would likely come out SMALL,
  not large;
- nothing: record the effect in `skills/optimize/measurement.md` and
  leave the arithmetic alone. This is a real option and may well be
  the right one.

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
2026-08-27 at `origin/main` `267c2a4d`).

## Relation to 3IUBNQZZ

3IUBNQZZ carries the founded, implementable half of the same evidence
base — labelling every table the perf gate prints with each side's
binary sha and measurement time — and names this item in its
Non-goals. This item is the unfounded half, deliberately left in the
backlog until someone is ready to answer its question, starting from
the fact that its data source has to be built before it can be read.
