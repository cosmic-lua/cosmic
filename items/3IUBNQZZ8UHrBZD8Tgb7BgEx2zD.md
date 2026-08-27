## Goal

G6 — the defining paths, ratcheted: a compare row can be traced to the
binary that produced it, and a scenario's noise floor is derived from
evidence rather than from one window's spread.

Goal narrowed 2026-08-27 (second rework of 3IU0GxoA, the item that is
this one's evidence base). Read the title as the hypothesis this item
opens with, not as a finding: "state-split" is NOT established, and no
verb renames an item (3IFWAdlL, band 1, backlog).

What 3IU0GxoA's Result actually establishes, and all this item may
assume:

- Over 40 isolated launches spanning 40 minutes on ONE recorded binary
  (`bin_sha c81de75b787a…`, cosmos `2026.08.27-13977f2ef`),
  `codec_base64_roundtrip_64k` held median 190.0 µs at **CV 2.1%**,
  unimodal, with no drift between the first and second halves. Within
  a window and a binary this scenario is STABLE — the earlier premise
  of a minutes-scale bimodal machine mode is withdrawn.
- Across the six isolated datasets on record the LEVEL spans 144.9 to
  227 µs with the codec source byte-identical throughout, every group
  is internally tight (CV 1.2-5.3%), and **every level step coincides
  with a change of binary**. The largest, 190.0 → 144.9 µs (~24%)
  eleven minutes apart, is between two cosmic builds over the same
  pinned cosmos. Machine state and build identity were never
  separated; no two datasets were measured back to back.
- The perf gate records nothing about which binary produced a row, so
  a level difference of this size can enter a compare with no trace.

So the surviving, actionable premise is a RECORDING gap, justified by
the confound EXISTING: the harness writes `meta.bin_sha` per run but
never stamps it into a compare row, so cross-binary readings can chain
silently. Deriving noise floors from cross-window A/A history remains
a HYPOTHESIS this item may test at plan against accumulated selfcheck
history — it is not a finding, and it is explicitly not a warrant to
widen any bar (see Non-goals).

## Change

Two parts, and only the first is founded today.

1. **Traceability, founded.** Stamp the producing binary into every
   compare row the harness prints, so a reader can see at a glance
   whether two rows came from the same binary. `_perf/run.tl` already
   writes `meta.bin_sha` into each results file; the shape and the
   files to touch are to be settled at plan.

2. **Noise floors from history, a hypothesis to test at plan.**
   Whether a per-scenario floor derived from accumulated same-binary
   A/A selfcheck spreads (the selfcheck pair is same-binary by
   construction) beats today's single-window `spread_pct` is an open
   question, and the first job at plan is to answer it from the
   selfcheck files the gate already writes — not to implement a
   derivation on the assumption. If the history shows what 3IU0GxoA's
   bracket shows for base64 (tight within a binary), the honest
   outcome for that scenario is a floor that does not move, and this
   part closes with that recorded.

Alternatives to weigh at refinement: a D31 amendment requiring an
interleaved A/B control before any single-window codec delta is read
as a code effect, or per-scenario `noise_floor_pct` in the scenario
module derived from the same history.

## Non-goals

- **No widening of `codec_base64_roundtrip_64k`'s noise floor**, and
  no change to any bar, on the evidence in 3IU0GxoA. That evidence
  makes this scenario look MORE stable within a window, not less: its
  40-run bracket is tighter than the ±4.8% figure 3ISlY5Xl's
  arithmetic used. 3ISlY5Xl held a release at +21.0% via
  `21.0 > max(10.0, 2 x 4.8)`; the cross-binary spread recorded in
  3IU0GxoA is not a noise budget, because no two of those datasets
  were measured back to back. Widening this scenario's floor would
  retire the arithmetic that kept that gate honest, and nothing here
  licenses it.
- No weakening or removal of codec rows from any compare.
- No scenario or `check()` changes.
- The interleaved A/B (skills/optimize/measurement.md) stays the
  instrument of record for codec claims; nothing here replaces it.

## Acceptance

To be written at refinement, with the derivation command and its
measured output quoted. Two bounds it must carry: the traceability
change is proved by a compare row printing a binary identity for both
sides, and no committed threshold for `codec_base64_roundtrip_64k`
may end larger than it starts.

## Enablement

3IU0GxoA's Result is the evidence base — read its by-binary table and
its "What this does NOT license" paragraph before refining. The gate
and selfcheck machinery already exist (#1432). The one open confound
3IU0GxoA names — the two recorded binaries were never measured back
to back — is closable with an interleaved A/B of
`c81de75b787a…` and `afdd72c09850…` over cosmos `13977f2ef`, and
doing that at plan would decide part 2 on evidence instead of on a
hypothesis.
