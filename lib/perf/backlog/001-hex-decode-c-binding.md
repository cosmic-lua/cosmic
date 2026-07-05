# 1. hex decode via the C binding

- status: done (2026-07-04)
- layer: cosmic
- scenario: codec_hex_roundtrip_64k

- result: 17.53ms -> 2.16ms (-87.7% first pass, -88.0% on re-measure)
- evidence: `codec.decode_hex` (lib/cosmic/codec.tl) was a pure-Lua
  `gsub("(%x%x)", callback)` — one closure call per byte pair, ~32k
  for 64KB — plus two full-string validation scans. `cosmo.DecodeHex`
  exists (lib/types/cosmo.d.tl:130) and was unused.
- fix: kept the existing Lua-side even-length and hex-character
  validation (so the documented `value, string` error returns and
  messages are unchanged — `cosmo.DecodeHex` raises a Lua error on
  odd length / non-hex input rather than returning nil+err, so
  validation must run first), then delegated the actual byte
  conversion to `cosmo.DecodeHex` instead of the gsub callback.
- result detail: no other scenario regressed (`bin/make perf-compare`:
  20 scenarios, 0 regression, 1 faster, 19 ok after a clean
  re-measure; an initial run flagged an unrelated `startup_*` scenario
  that didn't reproduce and isn't touched by this change).
