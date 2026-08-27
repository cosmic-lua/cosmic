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

## Bounce — 2026-08-27 14:2x UTC, returned to plan (session 0b13d2b4)

Pulled, re-measured, and returned unbuilt: the Change defers its own
shape to plan twice and the Acceptance is unwritten, so there is
nothing here that can be implemented from the spec alone. The
re-measurement below is recorded so the next refine starts from
pull-time numbers.

**Re-measured at pull.** Binary `145057b9fe90…` (`sha256sum
o/bin/cosmic`), cosmic main `267c2a4d`, built in this container.
Context ISOLATED, five launches 14:23-14:24 UTC:

```
o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out <scratch>/probe-N.json
```

187.50, 189.49, 193.96, 211.57, 221.10 µs/op — min 187.50, median
193.96, max 221.10, mean 200.72, sd 14.9, CV 7.4%. This session sits
on the **~190 level**, within 0.2% of 3IU0GxoA Review 3's afternoon
median of 194.32 µs on a different binary and within 2% of that
item's 40-run bracket median of 190.0 µs. So the Goal's shape holds
at pull: a session lands on one of the recorded levels and this one
landed on the slow one. Its dispersion is looser than the 40-run
bracket's CV 2.1% (the last two launches ran hot, `±13.0%` and
`±19.3%` within-run), which is a detail, not a shape change.

**The recording gap reproduces verbatim.** A/A selfcheck, same binary,
same window, `o/bin/cosmic --make run _perf/gate.tl selfcheck
<scratch>/aa-a.json <scratch>/aa-b.json --only
codec_base64_roundtrip_64k` printed:

```
codec_base64_roundtrip_64k      201.49 µs ->    214.04 µs     +6.2%  (noise  ±52.4%)  ok
perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold
```

Name, base, current, delta, noise, verdict — and no binary identity on
either side, which is the Goal's fourth bullet unchanged. Part 1 of
the Change is still real and still worth building.

**Why it bounced, three gaps, none of them mine to settle mid-slice.**

1. **`## Acceptance` is unwritten** — it reads "To be written at
   refinement, with the derivation command and its measured output
   quoted." The acceptance commands are the definition of done; with
   none, the slice has no closing condition and the reviewer has no
   evidence to demand.
2. **Change part 1 defers its own shape**: "the shape and the files to
   touch are to be settled at plan", and plan did not settle them.
   Today `_perf/compare.tl`'s `format_delta`/`format` print exactly the
   six fields above, and `meta.bin_sha` is read only by
   `identity_refusal`. Whether the identity lands as a report header,
   a per-row column, one side or both, short or full hex — and whether
   `format_delta`'s signature has to grow to carry it — is a design
   decision the spec reserves to plan, not a detail an implementer
   fills in.
3. **Change part 2's data source does not exist.** It asks for a floor
   derived "from the selfcheck files the gate already writes". The
   gate writes the two results files the CALLER names and persists no
   history: `_perf/gate.tl`'s `selfcheck` takes `A.json B.json`,
   measures into both, compares, and returns — nothing accumulates,
   and `o/perf/*.json` is never committed (AGENTS.md). There is no
   accumulated cross-window A/A history anywhere in the tree to derive
   a per-scenario floor from, so answering "does a history-derived
   floor improve on `spread_pct`" first requires DECIDING to build a
   history store and where it lives. That is the shape question the
   spec says plan must answer, and it is unanswered.

**What the next refine has to settle**, in this order:

- whether part 2 survives at all, given no A/A history store exists
  and the spec's own Non-goals forbid the widening it was reaching
  for; if it survives, name where the history lives, who writes it,
  and what the derivation reads.
- part 1's printed shape and the exact files, concretely enough that
  the diff is obvious from the sidecar.
- an Acceptance of runnable commands, carrying the two bounds the
  current spec already fixes: a compare row printing a binary identity
  for both sides, and no committed threshold for
  `codec_base64_roundtrip_64k` ending larger than it starts.

No tree diff and no PR: the branch cut for this slice
(`claude/3IUBNQZZ-noise-floors`, off `267c2a4d`) carries no commits.
