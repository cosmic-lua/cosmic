## Goal
G3 — the last cast of the original assert-dance arc: retire
`cosmic/coverage/init.tl`'s pack-n cast, licensed to come out the
moment the pinned checker types `table.pack(...)` over mixed arguments
as `PackTable<any>` with `n: integer`. That moment arrived: #1421
moved `bin/cosmic.pin` to `2026-08-27-afad5b5`, and the pin-bump's
recorded probe shows the pinned checker REFUSING
`local s: string = table.pack(1, "a").n` with "got integer, expected
string".

## Evidence
Measured 2026-08-27 against main after #1421/#1422:
- The site: `cosmic/coverage/init.tl:133`
  `return table.unpack(results, 2, results.n as integer)` with the
  two-line comment/marker above it (`:131-132`).
- The baseline row: `_build/casts_baseline.tl:31`
  `["cosmic/coverage/init.tl"] = 6` → 5 after.
- The cold-build rule (3ISKgfS6): generation 1 compiles the tree with
  the PINNED checker, so the direct proof is the pinned bootstrap
  binary accepting the edited file.

## Change
Delete the cast and its two comment lines; the line becomes
`return table.unpack(results, 2, results.n)`. Regenerate
`_build/casts_baseline.tl` with the ratchet's printed command.

## Non-goals
No behavior change; no other cast; no coverage-instrumentation edit.

## Acceptance
- `o/bootstrap/cosmic --check types cosmic/coverage/init.tl` passes
  (the pinned gen-1 checker accepts the cast-free file).
- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c -- "-- cast:" cosmic/coverage/init.tl` prints 5 (today 6).
- `grep "cosmic/coverage/init.tl" _build/casts_baseline.tl` shows
  `= 5` (today `= 6`).
- `bin/cosmic --make test cosmic/coverage/init_test.tl` passes and
  `o/bin/cosmic --make coverage` ends `coverage: PASS`.
- Diff touches exactly `cosmic/coverage/init.tl` and
  `_build/casts_baseline.tl`.

## Enablement
none needed — the discriminating probe already ran in #1421's body.
