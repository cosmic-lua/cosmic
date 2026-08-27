## Goal

The cosmos pin (`3p/cosmos/cosmos_pin.tl`) names a release whose base
carries whilp/cosmopolitan#284's merge (ScanLongString CR
normalization — 3INGg7XO's stage 1), unblocking 3INGg7XO stage 2 (the
Teal reader's matching change). Status 2026-08-27T04:12Z: #284 MERGED
to master as `13977f2e` (owner approved in chat); the push-to-master
Release run 33038563430 is in flight (started 04:09:57Z; the prior
release took ~10 min).

## Change

The same two-line bump 3ITnbooy just exercised (PR #1426, merged
2026-08-27 04:12Z), against the next release:

1. Wait for Release run 33038563430 to publish; its tag will be
   `2026.08.27-13977f2e` (the tag names the master short sha, so
   `git merge-base --is-ancestor 13977f2e <tag sha>` holds trivially).
2. `3p/cosmos/cosmos_pin.tl`: version line to the new tag, sha line
   to the `cosmos.zip` digest from the release's own SHA256SUMS.
3. Verification per the pin-bump procedure (AGENTS.md + the optimize
   skill's landing step, exactly as PR #1426 ran it): baseline
   `_perf/run.tl` on the OLD pin first, then bump + `--make fetch` +
   `--make ci`, then measure and `gate.tl compare` with
   `--baseline-bin` pointing at a cosmic built on the old runtime —
   quote the `perf-compare:` verdict line in the PR.
4. PR with the pin diff only, `Board: 3ITyKzff`.

The window 3977e62f2..13977f2e carries ONLY #284 (llua.c ScanLongString
+ test_llua.lua; measured: `git log 3977e62f..13977f2e --oneline` on
whilp/cosmopolitan is that one squash commit). No `definitions.lua`
change, so no type-surface movement; DecodeLua's signature and error
channel stand.

## Non-goals

No scenario edits, no threshold overrides; a `regression` row that
survives the fixed gate's triage (strike-twice + baseline retry,
#1432) is a finding to raise, not absorb. No `bin/cosmic.pin` change
(the cosmic-release pin is a different pin). No Teal-reader change
here — that is 3INGg7XO stage 2, which this unblocks.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS` on the new pin.
- `sha256sum o/3p/cosmos/lua` differs from the old pin's (runtime
  actually moved) — record both.
- `gate.tl compare` (with `--baseline-bin`) ends `perf-compare: PASS`.
- The pinned runtime resolves the CR case: `o/3p/cosmos/lua -e
  "local t = cosmo.DecodeLua('return {x = [[a\r\nb]]}'); print(t.x == 'a\nb')"`
  prints `true` (the #284 behavior, false on the old pin).
- Diff touches exactly `3p/cosmos/cosmos_pin.tl`.

## Enablement

none needed — the procedure was exercised minutes ago by PR #1426
under the fixed gate; the release is the only wait, and it is in
flight (run 33038563430).
