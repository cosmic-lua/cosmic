## Goal

G6 — re-green the release lane. The accepted bisect (3ITOUv0w) names
cosmos `354c17e08` ("DecodeLua: a Lua-literal data parser in C",
tool/net/llua.c +650) as the single commit holding
`codec_base64_roundtrip_64k` +20% and every release since
`2026-08-23-d71d7f1` unpublished. The base64 sources are untouched
across the range, so the leading hypothesis is code layout: the new
compiled C moved the base64 loops across an alignment or cache
boundary. This slice tests that hypothesis with a local rel-mode A/B
in whilp/cosmopolitan, lands the fix there, and unblocks the pin-bump
chain (3ISVlHT6 → 3ISPGV8z).

## Evidence

Measured/read 2026-08-27; checkout `/home/user/cosmopolitan` at
`3c36bc352` (one commit past the culprit).

- **The attribution**: 3ITOUv0w's Result — med 144.29 → 173.38 µs
  (+20.16%), trimmed ranges disjoint (146.52 < 171.54), floor 3.2%;
  the two commits before it flat (+0.50%, −0.11%). Four sessions
  agree on direction; magnitude ranges +7.8%…+25.7% by host.
- **The codec is untouched**: `git log --oneline
  07fc94a1c..354c17e08 -- net/http/encodebase64.c
  net/http/decodebase64.c net/http/isbase64.c | wc -l` → 0. The
  scenario's path is `LuaCoder` → `EncodeBase64`/`DecodeBase64`
  (`tool/net/lfuncs.c:946-951`), 253 lines of C across three files.
- **Mode matters**: the measured regression is in RELEASE binaries,
  and the released `lua` ships `MODE=rel` (cosmopolitan AGENTS.md).
  A layout hypothesis is mode-specific — default-mode builds lay out
  differently — so both the reproduction and the fix A/B must be
  rel-vs-rel local builds. `skills/optimize/measurement.md` records
  the same effect class measured on codec_hex with local rel builds.
- **The instrument** is `skills/optimize/cosmopolitan.md`: stand a
  local `lua` at `o/3p/cosmos/lua` in the cosmic tree, `--make
  build`, measure with `--make run _perf/run.tl --only
  codec_base64_roundtrip_64k`; interleave WHOLE build+measure cycles
  (4 pairs) and judge by direction-consistency; hash `o/bin/cosmic`
  each side (`--version` lies; the compare gate refuses same-hash
  sides). Never local-vs-released.
- **Container facts**: no `.cosmocc` yet (first build downloads the
  toolchain once — network available via proxy); no Linux `perf`
  binary — cycle profiling is out, but `nm -n` over two rel ELFs
  shows exactly where the base64 symbols land, which is the cheap,
  decisive layout diagnosis.
- **Fork rules**: surgical diffs; binding contracts frozen
  (`definitions.lua` untouched — an alignment fix moves no
  contract); gate with `make -j o//tool/lua/test` (default mode).
  Work lands on branch `claude/cosmic-types-asset-dance-8kdy49`.

## Change

All in `/home/user/cosmopolitan` (tree held at master `3c36bc352`
except where a step names a commit), measurement in `/home/user/cosmic`
on current main, only `o/3p/cosmos/lua` differing between sides.

1. **Diagnose the layout delta.** Build `MODE=rel o//tool/lua/lua` at
   `8dd093cea` (last flat arm) and at `354c17e08`; `nm -n` both,
   record the addresses and 64-byte alignment of `EncodeBase64`,
   `DecodeBase64`, `IsBase64`, and the base64 lookup tables. A shift
   in address/alignment of the hot symbols corroborates layout; no
   shift redirects the hypothesis (then diagnose data side: table
   cache-set placement) — record either way.
2. **Reproduce locally, rel-vs-rel.** Interleaved A/B, 4 pairs:
   A = `8dd093cea` rel `lua`, B = `354c17e08` rel `lua`, each cycle
   `cp <lua> o/3p/cosmos/lua && bin/cosmic --make build` (read the
   verdict directly) then one
   `--make run _perf/run.tl --only codec_base64_roundtrip_64k --out …`
   reading. B slower than adjacent A in ≥3 of 4 pairs = reproduced;
   otherwise record NOT REPRODUCED LOCALLY — the effect then lives in
   the release CI's toolchain and the follow-up is a gate/re-baseline
   decision for a human, not code; stop and write the result.
3. **The fix, smallest first**: at master, align the hot codec
   functions — `__attribute__((__aligned__(64)))` on `EncodeBase64`,
   `DecodeBase64`, `IsBase64` definitions (or the repo's existing
   alignment idiom if one exists — grep first and match it). Rebuild
   rel; `nm -n` must show the three at 64-byte boundaries.
4. **Judge the fix**: interleaved A/B, 4 pairs, A = unmodified master
   rel `lua`, B = master+fix rel `lua`. Keep iff B faster in ≥3 of 4
   pairs AND B's readings sit at or near step 2's fast side. If
   alignment does not restore, one fallback attempt is allowed with
   the same instrument (e.g. also aligning the lookup tables or the
   `LuaCoder` shim); a second failure ends the slice with the
   recorded numbers and a follow-up naming what was excluded — do not
   iterate blindly.
5. **Gates before PR**: `make -j4 o//tool/lua/test` (default mode)
   PASS; then the full-suite compare on the cosmic side — baseline =
   unmodified master rel local, current = fixed rel local,
   `gate.tl compare` — no non-noise regression elsewhere.
6. **PR to whilp/cosmopolitan** on branch
   `claude/cosmic-types-asset-dance-8kdy49`: the alignment diff only,
   body quoting the nm addresses, the step-2 reproduction pairs and
   the step-4 fix pairs. No `definitions.lua` change. Hand the item
   to check with the PR number.
7. **Record on the item** (spec append): the nm evidence, both
   interleaves' per-pair numbers, and the verdict.

## Non-goals

- **No contract change**: return shapes, error values, constants and
  `definitions.lua` untouched; an alignment attribute changes no
  observable behavior.
- **No scenario edits**, no `--samples`/`--min-secs` overrides, no
  gate weakening; never local-vs-released comparisons.
- **No revert of `354c17e08`** — DecodeLua is shipped API cosmic
  already consumes (`cosmic.literal` compact path); the fix
  neutralizes the side effect, not the feature.
- **No release.yml dispatch and no pin bump** — 3ISVlHT6 owns the
  bump once a release publishes green.
- **No default-mode accept/reject decisions** — rel-vs-rel only for
  the layout question; default mode is for the correctness gate.
- **A cosmic-side tree change is out of scope**; only
  `o/3p/cosmos/lua` varies between measured sides.

## Acceptance

- The item's spec carries the step-1 nm table, and both interleaves'
  per-pair µs numbers with an explicit ≥3-of-4 verdict line each.
- `make -j4 o//tool/lua/test` ends PASS on the fix commit.
- The full-suite `gate.tl compare` (unmodified-local baseline vs
  fixed-local current) ends `perf-compare: PASS`.
- A PR exists in whilp/cosmopolitan on
  `claude/cosmic-types-asset-dance-8kdy49` containing only the
  alignment diff, body quoting the numbers; the item is in check with
  its `pr` field set (cross-repo: the item's repo names
  whilp/cosmopolitan).
- `git -C /home/user/cosmopolitan status --short` clean but for the
  committed fix; no cosmic-tree file changed
  (`git -C /home/user/cosmic status --short` clean).
- Escape hatches, each a recorded result instead of a PR: step 2 NOT
  REPRODUCED LOCALLY → result + human-decision follow-up; step 4
  double failure → result + follow-up naming the excluded fixes.

## Enablement

The cosmocc toolchain is not yet downloaded (first `make` fetches it;
proxy network verified for github hosts). No Linux `perf` here — the
nm diagnosis and the interleave carry the whole decision, and the
spec is written so neither needs a profiler. Everything else
(pin-swap embed, interleave, gate) is the `optimize` skill's standing
instrument, exercised by four prior sessions on this exact scenario.

## Result

Measured 2026-08-27, container independent of the four prior sessions.
All rel-mode local builds; every binary hashed; `o/bin/cosmic` hashes
differed per arm and repeated exactly across pairs.

**Step 1 — nm layout diagnosis** (rel `lua.dbg`, `nm -n`):

| symbol | 8dd093cea (flat) | 354c17e08 (regressed) | master+fix |
|---|---|---|---|
| DecodeBase64 | 0x43a49c0 (64-al) | 0x43a7ca0 (32-al) | 0x43a7cc0 (64-al) |
| EncodeBase64 | 0x43a4cc0 (64-al) | 0x43a7fa0 (32-al) | 0x43a7fc0 (64-al) |
| IsBase64 | 0x43a6a60 (32-al) | 0x43a9d40 (64-al) | 0x43a9d80 (64-al) |

The regressing commit dropped the two hot entries from 64- to 32-byte
alignment; the fix (`forcealign(64)` on all three) restores 64.
Corroborating fact: master (`3c36bc352`) built byte-identical rel
`lua` to `354c17e08` (`f1ab6b39a24f…`), so #275 changed no layout and
"master" IS the regressed image.

**Step 2 — local reproduction interleave** (tree 5ef13f40 worktree,
`--only codec_base64_roundtrip_64k`, wall_ns medians):

| pair | 8dd093cea | 354c17e08 | delta |
|---|---|---|---|
| 1 | 97.86 µs (±24.8%) | 122.98 µs (±0.6%) | +25.67% |
| 2 | 123.67 µs (±6.0%) | 124.58 µs (±1.1%) | +0.73% |
| 3 | 121.34 µs (±1.2%) | 125.70 µs (±9.8%) | +3.59% |
| 4 | 121.49 µs (±5.7%) | 125.83 µs (±13.3%) | +3.57% |

Direction-consistent 4/4 → REPRODUCED, with a host confound read off
the data: the flat arm itself stepped 97.9 → ~122 µs (same binary,
same hash) after pair 1 — boost decay — so the release-scale +25.7%
expresses only in the boosted regime; steady state on this host shows
~+3.6%.

**Step 4 — fix interleave** (master vs master+fix, same instrument):

| pair | master | master+fix | delta |
|---|---|---|---|
| 1 | 141.00 µs (±8.2%) | 142.41 µs (±4.5%) | +1.00% |
| 2 | 128.46 µs (±4.2%) | 128.21 µs (±3.5%) | −0.19% |
| 3 | 126.39 µs (±5.2%) | 127.72 µs (±15.8%) | +1.05% |
| 4 | 124.77 µs (±1.1%) | 126.18 µs (±9.2%) | +1.13% |

Fix faster in 1 of 4 pairs → **NOT VALIDATED on this host**. The rule
required ≥3/4.

**What the two results together mean.** With entry alignment restored,
the fixed functions' INTERNAL layout equals the fast build's exactly
(same compiler, same source, entry congruent mod 64) — yet none of the
steady-state +3.6% comes back. So entry/loop alignment of the codec
functions is not the operative mechanism; what remains is
relative-position effects between images (branch-predictor/BTB
aliasing between the codec loops and the Lua VM's dispatch loop, which
the harness re-enters between iterations) and a strong frequency
dependence (the effect is 7× larger boosted than steady). Neither is
addressable by pinning the codec symbols, and this host cannot
adjudicate a candidate: its steady-state expression (+3.6%) sits
inside the pairwise spreads.

Excluded by measurement or by anti-correlation: codec entry alignment
(this slice, fix interleave); internal loop alignment (implied by
entry congruence); lookup-table alignment (the FAST build had kBase64
at 32-al, the regressed at 64-al — anti-correlated).

**Correctness**: `make o//tool/lua/test` on the fix — see PR #280 for
the verdict line; the change is three alignment attributes, no
contract move.

**Disposition.** PR whilp/cosmopolitan#280 stays DRAFT carrying the
full numbers. The decision it tees up is a human's, per this item's
own non-goals: either (a) land the safe-but-locally-unvalidated pin
and let release.yml — the only instrument on the affected host class —
measure it against the previous release, or (b) re-baseline via a
`perf_gate: false` dispatch, accepting the +21% as the new floor for
this scenario on that host. follow-up: 3ITbywUBOB6CfnjtGOBlGRqgll1 carries that decision.
