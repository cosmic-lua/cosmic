# 9. hash.sha256_hex dead `:lower()` call

- status: done (2026-07-04)
- layer: cosmic
- scenario: hash_sha256_small

- result: `hash_sha256_small` (new scenario): 488.9ns -> 305.1ns
  first pass (-37.6%), 300.8ns on re-measure (-38.5%)
- evidence: `sha256_hex` (lib/cosmic/hash.tl) was
  `codec.encode_hex(cosmo.Sha256(data)):lower()`. Verified at runtime
  that `cosmo.EncodeHex` (which `encode_hex` delegates to directly)
  already emits lowercase hex, so `:lower()` was a dead full-string
  scan + allocation on every call, on top of the digest — same
  "wrapper redoes work the C binding already did" shape as the
  hex-decode fix (entry 1), just smaller.
- fix: removed the `:lower()` call; existing tests already assert
  lowercase output and a known digest value, so this is provably a
  no-op removal, not a behavior change.
- added `hash_sha256_small` to `lib/perf/bench/micro_bench.tl`
  (hashing `"abc"`, the NIST test vector) alongside the existing
  `hash_sha256_1mb`: the 1MB scenario's SHA-256 compute swamps a
  fixed-per-call wrapper cost like this one, so it needed a tiny-input
  scenario to show up at all — `hash_sha256_1mb` itself was
  unaffected (within noise), as expected.
- result detail: `bin/make perf-compare` from a clean re-baseline,
  confirmed on a second re-measure: 22 scenarios, 0 regression,
  1 faster, 21 ok.
