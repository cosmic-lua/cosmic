# 14. compress.deflate/inflate size-prefix pack/unpack

- status: rejected (2026-07-04)
- layer: cosmic
- scenario: compress_deflate_roundtrip_small

- evidence: `compress_deflate_roundtrip_small` (new): 6.84µs baseline;
  deflate-only fix measured +0.2% then +1.7% (no win); deflate+inflate
  together measured +1.3% then -0.3% (still no win) across four
  separate measurements.
- hypothesis: `deflate` built a 4-byte little-endian length prefix via
  `string.char(size % 256, math.floor(size/256) % 256, ...)`;
  `inflate` unpacked it via `data:byte(1,4)` plus multiply-adds.
  `string.pack("<I4", size)` / `string.unpack("<I4", data)` (Lua
  5.4's own C-backed pack/unpack, not a `cosmo.*` binding, but the
  same "let a C routine do it" idea) replace ~10 Lua ops with one
  call each — objectively simpler code.
- fix attempted: replaced the manual byte-char loop with
  `string.pack`/`string.unpack` in both functions (first deflate
  alone, then both together, to see if the combined effect crossed
  the noise bar either way — it didn't).
- why it was rejected despite being clean, simpler code: the
  `cosmo.Deflate`/`cosmo.Inflate` zlib calls themselves have enough
  fixed per-call overhead (state setup/teardown) that they swamp the
  few nanoseconds saved on prefix packing even for a 3-byte input —
  there's no input size where the Lua-side saving would be *more*
  visible, since zlib's per-call floor doesn't shrink with smaller
  inputs. Reverted both changes (`git checkout -- lib/cosmic/compress.tl`).
  Kept the new benchmark scenario per the "never remove a scenario"
  rule — it's a real, permanent addition to the suite even though
  this round's hypothesis on it didn't pan out.
- risk: n/a, rejected on measurement grounds, not correctness.
