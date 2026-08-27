## Capture — a human decision, not code

UPDATED 2026-08-27 after release run 33030086144 (the first compare
since 2026-08-23 to run to completion — the two _perf skew fixes
#1415/#1420 landed): the decision's facts changed.

- codec_base64_roundtrip_64k read +7.9% (141.27 → 152.43 µs), UNDER
  the ±10% bar — the +21% expression decayed with the new image's
  layout roll, matching 3ITVR6Ku's relative-layout mechanism finding.
  The draft alignment pin (whilp/cosmopolitan #280) is now robustness
  against future rolls, not the unblock.
- The gate failed instead on two marginal rows: json_decode_large
  +11.9% (778.38 → 871.12 µs; pin exonerated by 3ISWHyP7's A/B, and
  the scenario reads +12.6% against ITSELF in suite context) and
  hash_sha256_small +10.3% (291.7 → 321.6 ns; fixed-overhead layout
  microbench, hash_sha256_1mb flat at −0.1%).
- Per the gate's own remedy ("a real regression reproduces, noise
  does not"), one re-run was dispatched 2026-08-27 ~01:40Z. If it
  publishes, this item closes with option "neither" — the lane
  self-healed once it could measure.

Remaining decision if the re-run also fails on the same marginal
rows: the flags are instability of the two scenarios, not
regressions — the call becomes a perf_gate:false re-baseline (the
gate's documented accept) or scenario-stability work
(json_decode_large's suite-context self-drift and the
fixed-overhead microbench class) before any release can pass a ±10%
bar it cannot itself hold.

Blocked work behind this: 3ISVlHT6 (pin bump) → 3ISPGV8z.

## Result

Resolved 2026-08-27 01:43Z with no decision needed: the dispatched
re-run (33030635580) passed the perf gate — perf-compare: PASS — and
published `2026-08-27-afad5b5`, the first release since 2026-08-23.
Both marginal flags (json_decode_large +11.9%, hash_sha256_small
+10.3%) failed to reproduce, confirming them as the scenarios'
documented instability rather than regressions. Neither option was
exercised: no perf_gate:false, and cosmopolitan #280 stays a draft
robustness candidate. The lane self-healed once #1415/#1420 let it
measure. Scenario-stability work (json_decode_large's suite-context
self-drift; the fixed-overhead microbench class) remains open value,
already tracked by the flow's existing captures.
