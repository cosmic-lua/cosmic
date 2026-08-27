## Goal
G6 durability — consume the base64 loop pins. Cosmos release
`2026.08.27-3977e62f2` (published 02:34Z) carries cosmopolitan #281
(IsBase64 alphabet-scan pin) and #282 (DecodeBase64 quantum-loop pin),
both `.balign 64` durability measures that close the demonstrated
placement lottery (±93% on IsBase64 across identical builds). Bump
`3p/cosmos/cosmos_pin.tl` to it, with the compare gate against the
previous pin as the end-to-end confirmation.

## Evidence
Measured 2026-08-27:
- Current pin: `2026.08.26-fe7c36c4c`, sha `1b54fceb…`.
- Target: `2026.08.27-3977e62f2`, cosmos.zip sha
  `b8c2b5db0ee0f2bcb9febd32c171b7341876c252aad88a8dc6a3ad047838315b`
  (from the release's own SHA256SUMS). `git merge-base --is-ancestor
  3977e62f <tag sha>` holds trivially — the tag IS the merge sha.
- The window fe7c36c4c..3977e62f2 carries #279 (EncodeLua reserved-word
  dispatch), #281, #282 — no binding contract change, no
  definitions.lua surface change beyond what the tree already consumes,
  so no type breakage expected (AGENTS.md: types regenerate in the
  build; a surface change would fail generation loudly).
- Landing procedure: optimize skill, "landing a C-layer win" step 3 —
  fetch, build, ci, and `gate.tl compare` against a baseline taken on
  the OLD pin, quoted in the bump commit.

## Change
1. `3p/cosmos/cosmos_pin.tl`: version and sha lines only.
2. Baseline first on the OLD pin: `bin/cosmic --make run _perf/run.tl
   --out o/perf/oldpin.json`; then bump, `--make fetch`, `--make ci`;
   then `--make run _perf/run.tl --out o/perf/newpin.json` and
   `gate.tl compare o/perf/oldpin.json o/perf/newpin.json
   o/perf/selfb.json` — read the verdict line; quote the
   codec_base64_roundtrip_64k row in the commit.
3. PR with the pin diff only.

## Non-goals
No scenario edits, no threshold overrides; a `regression` row that
survives the gate's triage is a finding to raise, not absorb; no
bin/cosmic.pin change (that is the cosmic-release pin, already bumped).

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS` on the new pin.
- `sha256sum o/3p/cosmos/lua` differs from the old pin's (runtime
  actually moved) — record both.
- `gate.tl compare` ends `perf-compare: PASS` (base64 expected flat to
  faster; layout rows may read `noise` per D31's triage).
- Diff touches exactly `3p/cosmos/cosmos_pin.tl`.

## Enablement
none needed — the procedure is the optimize skill's, exercised at the
last pin bump (#1395); the release and its sha are verified above.
