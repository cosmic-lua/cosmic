`codec_base64_roundtrip_64k` is reproducibly slower on the cosmos build
`2026.08.24-354c17e08` than on `2026.08.21-07fc94a1c`, and no source in
its path changed between them — so the cause is what the bump did to the
binary, not to the codec.

Measured 2026-08-26 under cosmic board item `3ISWHyP7`, on a 4-core
container. The A/B holds the cosmic tree fixed at `ea71d799^`
(`5ef13f40`) in a worktree and varies ONLY `3p/cosmos/cosmos_pin.tl`, so
the two binaries differ by the cosmos base and nothing else. Six rounds,
alternating sides, each an isolated single-scenario run
(`o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k`):

| round | pin | µs/op | ± |
|---|---|---|---|
| 1 | 07fc94a1c | 191.73 | 14.2% |
| 2 | 354c17e08 | 227.05 | 9.8% |
| 3 | 07fc94a1c | 196.18 | 13.1% |
| 4 | 354c17e08 | 206.34 | 7.0% |
| 5 | 07fc94a1c | 193.46 | 4.8% |
| 6 | 354c17e08 | 208.58 | 3.3% |

Medians 193.46 → 208.58 µs, **+7.8%**. The two sets do not overlap: the
fastest 354c17e08 reading (206.34) is slower than the slowest
07fc94a1c reading (196.18). Direction is consistent in all three
pairings. Read the caveat with it: the per-run ± is larger than the
effect on the noisy rounds, so the separation rests on the
three-per-side ranges rather than on any single pair, and a
confirmatory A/B on quieter hardware is the first thing to do here.

What did NOT change across `07fc94a1c..354c17e08`:

- `git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c
  net/http/decodebase64.c net/http/isbase64.c` → no commits. The codec
  is byte-identical.

What did:

- Five commits. The only one that changes what the binary CONTAINS is
  `354c17e0` ("DecodeLua: a Lua-literal data parser in C, beside the
  JSON one", #274): `git show --stat 354c17e0` → +991 lines, all
  additions, adding `tool/net/llua.c` (650 lines) as a new translation
  unit plus its `BUILD.mk` entry. `8dd093ce` touches only
  `third_party/lua/luaencodejsondata.c` (the JSON ENCODE path);
  `5bfcf79d` touches `libc/runtime/zipos-open.c`. Neither is on the
  base64 path.

So the leading hypothesis is code layout: adding a translation unit
moved the base64 encode/decode loops across an alignment or cache
boundary. First things to try, cheapest first:

1. Reproduce on a quiet machine, `MODE=rel` both sides, to confirm the
   effect size outside a shared container.
2. Bisect the five commits by building lua at each and running the same
   isolated scenario — if `354c17e0` alone carries it with the codec
   untouched, layout is confirmed.
3. If layout: check the alignment of `EncodeBase64`/`DecodeBase64` in
   both binaries (`nm`/`objdump` on `o//tool/lua/lua.dbg`) before
   reaching for any source change.

Why it matters: this is one of the two scenarios that has kept
`release.yml`'s perf gate red since 2026-08-24 (the other,
`json_decode_large`, was exonerated by the same A/B — it drifts ~11%
against itself and the 354c17e08 side was if anything faster and more
stable). Until this has an answer, cosmic cannot re-baseline the
release gate honestly.

A whilp/cosmopolitan change here must not move any binding contract:
return shapes, error values and constants at the C boundary are frozen
for cosmic's generated types.
