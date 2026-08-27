## Goal

G6 — the defining paths, ratcheted: a compare row can be traced to the
binary that produced it, and a codec claim never rests on readings
taken in two different measurement sessions.

Goal rewritten 2026-08-27 (second rework of 3IU0GxoA, this item's
evidence base). Read the title as this item's opening hypothesis, not
as a finding: "state-split" as the title states it is NOT established,
and no verb renames an item (3IFWAdlL, band 1, backlog).

What 3IU0GxoA's Result establishes, and all this item may assume:

- **Within one measurement session the scenario is stable.** 40
  isolated launches over 40 minutes on one recorded binary
  (`bin_sha c81de75b787a…`, cosmos `2026.08.27-13977f2ef`) held median
  190.0 µs at **CV 2.1%**, unimodal, with no trend between the first
  and second halves. Every other labeled group on record is internally
  tight at CV 1.2-5.3%. The earlier premise of a minutes-scale bimodal
  machine mode is WITHDRAWN — this item's own data refutes it.
- **Between sessions the absolute level moves 20-33% with the binary
  BYTE-IDENTICAL.** 3ISlWFiS and 3ITOUv0w each measured cosmic
  `d8492168eace…` (`sha256sum`-verified in both, and a third time by
  3ITHROpY) with the same isolated command: median 191.31 µs in one
  session, 144.29 µs in the other, raw ranges disjoint (+32.6%). Its
  sibling arm `940f21bb…` read 209.35 and 173.38 the same way
  (+20.7%). The two ratios differ, so it is not a uniform frequency
  scaling, and nothing observable inside the container moved.
- **A real regression's measured magnitude depends on which level the
  session landed on.** The same code delta read +9.44% interleaved at
  the ~191 level (3ISlWFiS) and +20.16% interleaved at the ~144 level
  (3ITOUv0w) — both verdicts REPRODUCED, both correctly interleaved
  within one session. So a fixed-percentage bar has a different
  sensitivity from session to session even on a correctly interleaved
  pair.
- **The gate records nothing about which binary produced a row.** The
  harness writes `meta.bin_sha` per results file and never stamps it
  into a printed compare row, so two rows from different binaries — or
  from different sessions — can chain silently.

The founded, actionable premise is therefore a RECORDING gap plus a
level-dependent sensitivity, not a wider bar.

## Change

Two parts, and only the first is founded today.

1. **Traceability, founded.** Stamp the producing binary into every
   compare row the harness prints, so a reader can see at a glance
   whether two rows came from the same binary and the same run.
   `_perf/run.tl` already writes `meta.bin_sha` into each results
   file; the shape and the files to touch are to be settled at plan.

2. **Level-aware sensitivity, a hypothesis to test at plan.** Whether
   a per-scenario floor derived from accumulated same-binary A/A
   selfcheck spreads (the selfcheck pair is same-binary AND
   same-session by construction) improves on today's single-window
   `spread_pct` is an open question, and the first job at plan is to
   answer it from the selfcheck files the gate already writes — not to
   implement a derivation on the assumption. Note what the evidence
   already says: same-session spread is TIGHT at both levels, so a
   history-derived floor would likely come out small, and the real
   sensitivity problem is that the same delta measures ~2x larger at
   the fast level. A floor expressed relative to the session's own
   measured level, or a normalisation of the delta by it, is the
   shape worth weighing first.

Alternatives to weigh at refinement: a D31 amendment requiring an
interleaved same-session A/B before any codec delta is read as a code
effect (which is what 3ISlWFiS and 3ITOUv0w already did by hand), or
per-scenario `noise_floor_pct` in the scenario module derived from the
same history.

## Non-goals

- **No widening of `codec_base64_roundtrip_64k`'s noise floor**, and
  no change to any bar, on 3IU0GxoA's evidence. That evidence makes
  this scenario look MORE stable within a session, not less: its
  40-run bracket is tighter than the ±4.8% figure 3ISlY5Xl's
  arithmetic used. 3ISlY5Xl held a release at +21.0% via
  `21.0 > max(10.0, 2 x 4.8)`, and the release lane measures baseline
  and candidate in the SAME job on the SAME runner — the interleaved
  shape the cross-session effect cannot reach. The 20-33% cross-session
  spread is not a noise budget for that gate; treating it as one would
  retire the arithmetic that kept it honest over a regression two
  independent interleaved experiments have since confirmed.
- No weakening or removal of codec rows from any compare.
- No scenario or `check()` changes.
- The interleaved A/B within one session
  (skills/optimize/measurement.md) stays the instrument of record for
  codec claims; nothing here replaces it.

## Acceptance

To be written at refinement, with the derivation command and its
measured output quoted. Two bounds it must carry: the traceability
change is proved by a compare row printing a binary identity for both
sides, and no committed threshold for `codec_base64_roundtrip_64k`
may end larger than it starts.

## Enablement

3IU0GxoA's Result is the evidence base — read its byte-identical
cross-session control table and its "What this does NOT license"
paragraph before refining. 3ISlWFiS and 3ITOUv0w carry the per-arm
readings and hashes that control rests on. The gate and selfcheck
machinery already exist (#1432).
