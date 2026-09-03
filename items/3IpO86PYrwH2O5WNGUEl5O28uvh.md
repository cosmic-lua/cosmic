## Evidence

PR #1656's reviewer, from a fresh checkout: `seed.cleanup()` runs in
`sources()` after `stamp_types`, on the success path only. A generator
failing between `seed.run` and the end of the loop returns early and
leaves `o/_types/types_seed` on disk; `closure_argv`'s check is
presence-only (`fs.is_present(seed.SEED_DIR)`), so the NEXT build
prepends a stale seed to every closure compile. Unreachable today
because `_types/types_gen.tl` sorts last among root-scope generators
(verified by breaking `cmd/cosmic/embed_gen.tl`: no orphan), and live
the day a third root-scope generator sorts after it.

## Change

`_make/generate.tl` `sources()`: every early `return` after
`seed.run` succeeds goes through `seed.cleanup()` first (a local
`fail(msg)` closure that cleans and returns `nil, msg`, or wrap the
generator loop in a function whose result is inspected after an
unconditional cleanup). `_make/seed.tl` `should_seed`: also true when
`SEED_DIR` exists but `o/_types/types_gen` is absent, so a stale seed
is re-run rather than trusted.

`_make/generate_test.tl`: a fixture whose stub generator fails after
the seed ran asserts `o/_types/types_seed` is absent afterwards and
the failure message survives.

## Non-goals

No change to the seed's contents or to `closure_argv`'s include order.
