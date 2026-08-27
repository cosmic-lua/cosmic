## Capture

The codec scenarios' per-op time swings ~25-30% across minutes at the
whole-machine level, on BOTH cosmos runtimes, defeating any
single-window claim about base64 performance.

Evidence (2026-08-27, one container, nproc=4, all values
codec_base64_roundtrip_64k):
- 02:37-03:25 window: old runtime (fe7c36c4c) 127.25 / 119.03 µs;
  new runtime (3977e62f2) 95.80 / 98.30 / 96.78 µs — the -24.7%
  "win" the pin bump (#1426) was measured to deliver.
- 03:47-03:51 (the fixed gate's PASS run): old 124.33, new 126.34 —
  EQUAL, +1.6% ok.
- ~04:02, same minute, two processes: old-runtime baseline retry
  96.78 (fast mode); #1439-tree binary 122.96 (slow mode).
- 04:07-04:12: twelve separate launches, six per runtime, ALL
  116-133 µs — the fast mode gone machine-wide.
- Meanwhile url_decode_query_value, time_format_* and other
  microbenches stayed consistent across the same windows, so this is
  not a global clock change reading; codec_hex swings with base64.

The in-image loop pins (cosmopolitan #281/#282) hold by construction
— a fixed binary's layout cannot drift between launches — so the
swinging factor is host/launch state (frequency or thermal state,
container CPU quota, per-launch mapping alignment of the 64KB
buffers). Implications: 3ITVR6Ku's +20% attribution and any codec
row in a release compare inherit this; the E1/E2 interleaved A/B
methodology (alternating launches within one window) remains the
only instrument that can see through it, and even it cannot bridge
windows. Candidate next steps for refinement: pin the mechanism
(perf counters? frequency read before/after each scenario, recorded
in meta), or make the codec scenarios longer-running to average
across the state, or record and gate on cpu_ns rather than wall.
