## Evidence

`3ITOUv0w` finished the bisect: the `codec_base64_roundtrip_64k`
regression that has held `release.yml`'s `compare against the previous
release` step red since `2026-08-23-d71d7f1` was moved by cosmos commit
**`354c17e08`** — "DecodeLua: a Lua-literal data parser in C, beside
the JSON one (#274)", `tool/net/llua.c` +650 new lines plus
`tool/lua/lcosmo.c` +23 and a `definitions.lua` entry.

The numbers, measured 2026-08-26 on cosmic tree `5ef13f40` with only
the two lines of `3p/cosmos/cosmos_pin.tl` varied, nine isolated
round-robin readings per arm at the default `--samples`/`--min-secs`.
Per arm, `min` / trimmed-low `r2` / median `r5` / trimmed-high `r8`, in
µs: base `2026.08.21-07fc94a1c` 141.61 / 142.57 / **144.29** / 146.52;
`5bfcf79d0` 141.69 / 143.06 / **145.01** / 149.49; `8dd093cea` 140.06 /
143.42 / **144.13** / 146.11; `354c17e08` 170.41 / **171.54** /
**173.38** / 176.14. The same-binary noise floor from eight
`gate.tl selfcheck` passes was **3.2%**. Under the verdict rule
`3ITOUv0w` was given, only `354c17e08` clears all three conditions:
median **+20.16%** over the base, trimmed ranges disjoint (base high
146.52 µs < `354c17e08` low 171.54 µs), delta far past the 3.2% floor.
The other two candidates read +0.50% and -0.11% with overlapping
ranges. The separation is wide enough that the raw nine-reading ranges
are disjoint too (base [141.61, 149.19] vs [170.41, 178.32]).

That +20.16% matches the **+21.0%** the release gate itself recorded
for this scenario on 2026-08-24, quoted in
[D31](../../docs/decisions/d31-gate-noise-from-every-control-pair.md),
which already concluded this one "is real and is worked where it
lives, in whilp/cosmopolitan". Four independent sessions now agree on
the direction and rough size (`3ISWHyP7` +7.8%, `3ISlWFiS` +8.35%,
`3ITHROpY` +25.70% median with no separation, `3ITOUv0w` +20.16%
separated), and `3ITOUv0w` rebuilt all four arms' `o/bin/cosmic`
byte-for-byte identical to `3ITHROpY`'s, so the instrument is
reproducible across sessions and containers.

**The leading hypothesis is code layout, not the codec.** The base64
sources did not change anywhere in the range —
`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
→ `0` — and the scenario's whole path is C
(`_perf/bench/micro_bench.tl:116-129` → `cosmic/codec.tl:37,82,83` →
`cosmo.EncodeBase64` / `cosmo.IsBase64` / `cosmo.DecodeBase64`). So the
650 lines of new compiled code most likely moved the base64 loops
across an alignment or cache boundary. `skills/optimize/measurement.md`
records the same class of effect measured directly on `codec_hex`
(local rel straddled vs padded, 122 µs vs 140 µs on the same source).

**What this item is.** Read `354c17e08`'s diff in whilp/cosmopolitan,
test the layout hypothesis against it (alignment of the base64 symbols
before and after, and whether padding or ordering restores the base
timing), and land a fix there. The A/B instrument is
`3ITOUv0w`'s: a worktree at cosmic `5ef13f40` with the pin swapped,
`--make fetch && --make build`, then
`_perf/run.tl --only codec_base64_roundtrip_64k` readings against the
`07fc94a1c` baseline of 144.29 µs — except that a candidate fix needs a
LOCAL whilp/cosmopolitan build, so `skills/optimize/cosmopolitan.md`'s
rule binds: baseline an unmodified local build and A/B two local builds
differing only by the change, never a local build against a released
one. Any fix must not move a binding contract — return shapes, error
values and constants at the C boundary are frozen for cosmic's
generated types, and `tool/net/definitions.lua` is the source of truth
cosmic generates from.

Landing this re-greens the release lane, which is what `3ISVlHT6`'s pin
bump has been waiting on: no cosmic release has published since
2026-08-23, and scheduled runs `32699814015`, `32818853162` and
`32940138465` all died at the perf-compare step with the `release` job
skipped.
