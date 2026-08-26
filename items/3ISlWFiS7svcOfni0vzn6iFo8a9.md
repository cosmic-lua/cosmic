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

- Five commits, of which **three change compiled code** — read per
  commit with `git show --stat <sha>`, which is what this claim needs;
  a path-filtered `git log` cannot establish it:

  - `354c17e08` ("DecodeLua: a Lua-literal data parser in C, beside the
    JSON one", #274) → 7 files, +991, all additions: `tool/net/llua.c`
    (650 lines) as a NEW translation unit, `tool/lua/lcosmo.c` (+23),
    two `BUILD.mk` entries.
  - `8dd093cea` ("EncodeJson: a float always encodes carrying a `.` or
    an exponent", #273) → `third_party/lua/luaencodejsondata.c`
    (+11/-1), the JSON encode path.
  - `5bfcf79d0` ("zipos: recycle the stored-member handle", #272) →
    `libc/runtime/zipos-open.c` (+62/-9), `zipos.internal.h` (-1).

  The other two are inert for compiled output: `8e071ec98` adds only
  sqlite3 header stubs whose two `#include`s sit in branches no
  compiler here takes (`sqlite3.c:203324` under `SQLITE_TEST`;
  `shell.c:898` under a guard the copy inlined at `shell.c:678-881`
  already defines), and `bf92718a1` touches `AGENTS.md`.

  **"Not on the base64 path" does not dismiss the other two here.** The
  hypothesis under test is LAYOUT, and any commit that changes compiled
  code shifts layout — that is the mechanism, not a side effect. So the
  encoder edit and the zipos rework are live candidates for this
  regression precisely because layout is what is suspected, even though
  neither touches base64 source.

So the leading hypothesis is code layout: added or changed compiled
code moved the base64 encode/decode loops across an alignment or cache
boundary. Which of the three did it is open. First things to try,
cheapest first:

1. Reproduce on a quiet machine, `MODE=rel` both sides, to confirm the
   effect size outside a shared container.
2. Bisect the five commits by building lua at each and running the same
   isolated scenario. Bisect all five rather than assuming
   `354c17e0`: three of them change the binary, so a result that lands
   on `8dd093ce` or `5bfcf79d` is a real outcome and not a
   measurement error.
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
