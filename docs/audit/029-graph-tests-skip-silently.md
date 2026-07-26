# 029 — `--make` graph tests degrade to green skips without the engine

severity: low
type: ci gap
area: `_make/fixtures_test.tl`, `_make/build_test.tl`, ci provisioning

## issue

the graph-executing tests exit 2 (skip) when the make engine is absent:
`_make/fixtures_test.tl:23-27` and `_make/build_test.tl:25-28` probe
`o/cosmo-make` and skip without it. ci provisions the engine via
`bin/make`, so today they run — but a provisioning regression (a path
change like the 3g `bin/cosmo-make` → `o/cosmo-make` move that already
burned half a day, a pin bump slip) silently converts the entire `--make`
graph-test surface into green skips. the suite would pass while testing
nothing.

## where

- `_make/fixtures_test.tl:23-27` — the skip guard.
- `_make/build_test.tl:25-28` — same.
- skip semantics: `status_of` treats 2 as skip, which the reporter shows
  but no gate counts.

## suggested fix

make the skip conditional on *intent*, not absence: in ci (e.g. when `CI`
is set, or via a `COSMIC_REQUIRE_MAKE=1` the ci lane exports), the missing
engine should be a hard fail. locally the skip stays, preserving the
cold-tree developer experience. alternatively (or additionally), have the
ci lane assert the reporter's skip count for `_make/` is zero.

## verification

temporarily rename `o/cosmo-make` in a ci run and confirm the lane fails
rather than passing with skips.
