Release run 33034667243 (2026-08-27, dispatched by the owner) failed
the perf gate on BOTH attempts with zero reproduction between them —
the gate is rolling dice on shared runners, not detecting
regressions. The evidence, from the two build-job logs:

- attempt 1 flagged http_stream_read_1mb +16.7% (floor ±16.5%);
  attempt 2 measured the same scenario -3.2% ok.
- attempt 2's final verdict flagged embed_extract_tree +25.7%
  (±15.9%) and json_decode_large +11.6% (±10.0%); attempt 1 had both
  ok (+0.3%, +5.5%).
- inside attempt 2, the gate's own retry pipeline flagged
  fs_barf_slurp_64k +54.6% (±32.5%) on the first compare and +0.8%
  on the retry; tar_extract_tree read "noise" on one pass and
  "regression" on another (+18.7%, ±13.6%).
- embed_extract_tree runs 2 (two) samples per measure; child-process
  and IO-heavy scenarios carry ±10-32% self-noise on these runners.

With 48 scenarios and marginal floors, the expected count of
false flags per run is near 1, so the release lane fails most rolls
regardless of the tree. The bisect work (3ITOUv0w, D31) already
learned the robust shapes: trimmed ranges, more readings for noisy
scenarios, reproduction as the bar. Candidate directions for the
slice, to be decided at refinement: require a flag to REPRODUCE in
the in-run retry before it fails the gate (the retry exists but a
NEW flag in the retry pass also fails); floor scenarios with
single-digit sample counts at their measured A/A swing rather than
10%; or a minimum sample count for gated scenarios. Never weaken a
scenario or its check(); the gate's statistics are the subject, not
the scenarios.

Separate observation worth carrying: json_decode_large has now
flagged high twice on different days (+12% in the 2026-08-26 red
that 3ISWHyP7 handled; +11.6%/+9.0%/+5.5% across today's measures,
same direction every time). If it flags again after the gate is made
reproduction-based, it earns its own bisect item rather than a
noise verdict.
