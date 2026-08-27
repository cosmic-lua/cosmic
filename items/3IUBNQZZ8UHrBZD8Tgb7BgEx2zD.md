## Goal

G6 — the defining paths, ratcheted: a codec compare row measured in
one machine window never stands alone, because the machine drifts
between at least four wall-time levels (96-98 / 116-133 / 138-156 /
184-202 µs for codec_base64_roundtrip_64k, measured 2026-08-27 on
byte-identical binaries; evidence and instrument eliminations in
3IU0GxoA's Result) and no in-container observable moves with the
level. The gate's noise floor for state-split scenarios derives from
cross-window A/A history — which captures the drift — instead of
single-window spread_pct, which cannot.

## Change

To be refined at plan: the shape sketched by 3IU0GxoA's conclusion is
a per-scenario floor derived from accumulated A/A selfcheck spreads
across windows (the gate already writes selfcheck files per run), fed
into `_perf/compare.tl`'s threshold for the scenarios whose history
shows multi-modal drift — likely a small committed table with a
derivation command, never a hand-tuned number. Alternatives to weigh
at refinement: a D31 amendment marking codec rows advisory outside
interleaved A/B, or per-scenario `noise_floor_pct` in the scenario
module derived from the same history.

## Non-goals

No weakening or removal of codec rows from any compare; no scenario
or check() changes; the interleaved A/B doctrine
(skills/optimize/measurement.md) stays the instrument of record for
codec claims.

## Acceptance

To be written at refinement, with the derivation command and its
measured output quoted.

## Enablement

3IU0GxoA's Result is the evidence base; the gate and selfcheck
machinery already exist (#1432).
