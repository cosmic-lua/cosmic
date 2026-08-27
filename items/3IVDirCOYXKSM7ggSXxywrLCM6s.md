## Evidence

Split out of 3IUBNQZZ at its third refine, which dropped it: the item
was carrying a founded traceability gap and this unfounded hypothesis
together, and the pairing made the spec unimplementable twice (two
bounces, both naming this half).

The open question is real. 3IU0GxoA's Result establishes that a real
regression's MEASURED MAGNITUDE depends on which absolute level the
measurement session landed on: the same code delta read **+9.44%**
interleaved at the ~191 µs level (3ISlWFiS) and **+20.16%** interleaved
at the ~144 µs level (3ITOUv0w), both verdicts REPRODUCED and both
correctly interleaved within one session. So a fixed-percentage bar
has a different sensitivity from session to session even on a
correctly interleaved pair — which is a property of the gate's
arithmetic, not of the machine.

3IUBNQZZ's spec reached for "a per-scenario floor derived from
accumulated same-binary A/A selfcheck spreads" as the answer. **The
data source does not exist.** `_perf/gate.tl`'s `selfcheck` takes
`A.json B.json`, measures into both, compares, and returns; nothing
accumulates, and `o/perf/*.json` is never committed (AGENTS.md). There
is no cross-window A/A history anywhere in the tree. So answering
"does a history-derived floor improve on today's single-window
`spread_pct`" first requires DECIDING to build a history store — where
it lives, who writes it, what reads it, and how a committed
measurement record avoids becoming a ratchet nobody can reproduce.

Note what the evidence already says against that shape before anyone
builds it: same-session spread is TIGHT at both levels (CV 2.1% over a
40-run bracket; 1.2-5.3% for every other labeled group on record), so a
history-derived floor would likely come out SMALL. The sensitivity
problem is not that the noise floor is mis-sized — it is that the same
delta measures ~2x larger at the fast level. A floor expressed
relative to the session's own measured level, or a normalisation of
the delta by it, is the shape worth weighing first, and it needs no
history store at all.

Alternatives to weigh before committing to any of them: a D31
amendment requiring an interleaved same-session A/B before any codec
delta is read as a code effect (which is what 3ISlWFiS and 3ITOUv0w
already did by hand), or per-scenario `noise_floor_pct` in the
scenario module.

**Bound on whatever comes of this**, carried over from 3IUBNQZZ's
Non-goals: no widening of `codec_base64_roundtrip_64k`'s noise floor
on this evidence. 3IU0GxoA makes that scenario look MORE stable within
a session, not less, and 3ISlY5Xl held a release at +21.0% via
`21.0 > max(10.0, 2 x 4.8)` measured in the SAME job on the SAME
runner — the interleaved shape the cross-session effect cannot reach.
The 20-33% cross-session spread is not a noise budget for that gate.

Evidence base: 3IU0GxoA's Result (the byte-identical cross-session
control table and its "What this does NOT license" paragraph),
3ISlWFiS and 3ITOUv0w for the per-arm readings and hashes.
