## Goal

G6 — the defining paths, ratcheted: a codec compare row measured in
one machine window never stands alone. The evidence (3IU0GxoA's
reworked Result): same-command ISOLATED readings of
codec_base64_roundtrip_64k drift across minutes-scale windows far
beyond the ±3.3-4.8% same-binary in-window spread prior work
measured (3ISlY5Xl/3ISWHyP7) — 190.2 vs 144.9 µs at medians eleven
minutes apart — while none of the instruments read (cpu/wall,
throttle, steal, pressure-absence) moves; binary-build identity
across windows is a confound the current gate never records. Both
facts argue the same countermeasure: the gate's noise floor for
state-split scenarios derives from same-binary cross-window A/A
history (the A/A selfcheck pair is same-binary by construction)
instead of single-window spread_pct, and the harness stamps
`meta.bin_sha` into every compare row it prints so cross-binary
readings can never chain silently.

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
