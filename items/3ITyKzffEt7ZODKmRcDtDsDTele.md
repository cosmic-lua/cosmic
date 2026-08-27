## Goal

The cosmos pin (`3p/cosmos/cosmos_pin.tl`) names the first release
whose base carries whilp/cosmopolitan#284's merge (ScanLongString CR
normalization — 3INGg7XO's stage 1), unblocking 3INGg7XO stage 2 (the
Teal reader's matching change). Twin of landed 3ITnbooy, one release
later.

## Evidence

Measured 2026-08-27:

- #284 merged to cosmopolitan master at 04:09:54Z as `13977f2e`
  (base was `3977e62f2`, the current pin's tag). The Release workflow
  fired on that push at 04:09:57Z and is the release this bump
  consumes: expected tag `2026.08.27-13977f2e` (tag = date + short
  sha of the push; the tag commit IS the merge, so
  `git merge-base --is-ancestor 13977f2e <tag sha>` holds trivially).
- Current pin: `2026.08.27-3977e62f2`, cosmos.zip sha `b8c2b5db…`
  (landed as 3ITnbooy, PR #1426, main `2a652545`).
- PULL-TIME GATE: the release must be PUBLISHED with its SHA256SUMS
  before this is workable — read cosmos.zip's sha from the release's
  own SHA256SUMS asset, never computed from a partial download. If
  the Release run failed, bounce and file the repair as its own item.
- The window 3977e62f2..13977f2e carries exactly #284 — no binding
  contract shape change, no definitions.lua surface change, so no
  type breakage expected (types regenerate in the build; a surface
  change fails generation loudly).
- One behavioral widening rides it, and it is the POINT: DecodeLua
  now accepts CR line-endings in long brackets (normalized like
  load). The cosmic side already agrees via the C-refusal
  fall-through for refused inputs, and `literal_engine_test.tl`'s
  corpus holds byte-agreement either way (long-bracket CR is not in
  the corpus until stage 2 adds it).

## Change

1. `3p/cosmos/cosmos_pin.tl`: version and sha lines only, per
   3ITnbooy's landed procedure verbatim.
2. Baseline first on the OLD pin: `bin/cosmic --make run
   _perf/run.tl --out o/perf/oldpin.json`; then bump, `--make fetch`,
   `--make ci`; then `--make run _perf/run.tl --out
   o/perf/newpin.json` and `_perf/gate.tl compare o/perf/oldpin.json
   o/perf/newpin.json o/perf/selfb.json` — read the verdict line and
   quote it in the commit. (No `--baseline-bin` here: both files are
   measured back-to-ack in one window by the same tree build; the
   flag exists for the release lane's cross-binary case.)
3. PR with the pin diff only.

## Non-goals

No scenario edits, no threshold overrides; a `regression` row that
survives the gate's triage is a finding to raise, not absorb; no
`bin/cosmic.pin` change; stage 2 of 3INGg7XO stays its own item —
this bump only opens its gate.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS` on the new pin.
- `sha256sum o/3p/cosmos/lua` differs from the old pin's (runtime
  actually moved) — record both.
- `_perf/gate.tl compare` ends `perf-compare: PASS`.
- The gate that this item exists for:
  `o/3p/cosmos/lua -e 'print((cosmo.DecodeLua("return {a = [[x\r\ny]]}")).a == "x\ny")'`
  prints `true` (the C reader normalizes — #284 is really in the
  runtime).
- Diff touches exactly `3p/cosmos/cosmos_pin.tl`.
- End this item on landing (its Result condition is this bump); drop
  the 3INGg7XO blocker edge in the same breath.

## Enablement

Waits only on the in-flight Release run (fired 04:09:57Z) publishing.
Procedure, gate and verbs are all exercised by 3ITnbooy.
