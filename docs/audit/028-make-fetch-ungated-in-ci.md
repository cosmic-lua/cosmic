# 028 — `--make fetch` never runs in ci against the real pins

severity: low/medium
type: ci gap
area: `.github/workflows/pr.yml`, `_make/fetch.tl`, `_make/pin.tl`

## issue

ci provisions third-party bytes exclusively through the old pipeline
(`bin/make` → `_build/build-fetch.tl`). the new `--make fetch` verb — and
specifically the machinery added in the final commit for the real pins (the
`platforms` table with per-`os-arch` `sha`/`format`, `{platform}`
substitution, and the `SSL_USE_SYSTEM_CERTS=1` default) — never executes in
any lane. a regression in platform resolution or cert handling would ship
and surface only when someone runs the fixpoint by hand.

## where

- `_make/pin.tl` — `platforms` resolution, added in 180b0d3.
- `_make/fetch.tl` — cert default, landing paths.
- pr.yml — no lane invokes `--make fetch`.

## suggested fix

cheapest first:

1. **offline half (no network):** a test that *resolves* both committed
   pins (`3p/cosmos/cosmos.pin.tl`, `3p/tl/tl.pin.tl`) for every platform
   key they declare, asserting url substitution and landing paths — this
   covers the resolution logic that actually broke during development
   ("`--make fetch` refused both real pins").
2. **online half:** run `cosmic --make fetch` for real in the lane that
   already has network for the bootstrap fetch, asserting PASS and the
   expected unpack products (`o/3p/tl/tl.lua`, `o/3p/cosmos/{lua,make}`).
   this also feeds 026's fixpoint lane.

## note

fixing 001 (satisfied-skips-unpack) first makes the online half's
assertions about unpack products meaningful on re-runs.
