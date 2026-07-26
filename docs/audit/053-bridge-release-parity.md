# 053 — bridge removal: the release artifact still comes from the Makefile

severity: blocker for 3i
type: gap (release parity)
area: `.github/workflows/release.yml`, `cosmic/cook.mk`, `_make/artifact.tl`

## what the release does today

release.yml runs `bin/make -j teal test build` and ships **two**
binaries: `cosmic-lua` (`o/bin/cosmic`) and `cosmic-lua-debug`
(`o/bin/cosmic-debug`, built in `cosmic/cook.mk` from the pinned
`lua-debug` runtime), plus SHA256SUMS.

## the gaps

1. **no debug variant concept.** a `--make` binary unit has one output
   and one `base` (`o/<unit>/base`). the debug artifact is the same
   payload on a different base — nothing in the model expresses "this
   unit, twice, on two runtimes." options: a second entry
   (`cmd/cosmic-debug/` with a two-line `embed.gen.tl` that reuses
   cosmic's payload — works today but duplicates the unit), or a
   variant concept (a unit output directory holding `base` and
   `base-debug`, producing `o/bin/<name>` and `o/bin/<name>-debug`).
   decide deliberately; the release shape is a public contract.
2. **artifact weight — item 9 / audit 045.** the `--make`-built cosmic
   is 10.2 MB against the Makefile's 8.7 because it ships `docs/`,
   `mk/`, `_perf/`, the Makefile itself as implicit assets. shipping
   that as the release is a regression users see; 045's decision
   (artifact = modules + `embed/**`) or an interim `.cosmicignore`
   must land first.
3. **no parity gate.** before release.yml switches builders, a lane
   should build both and compare: same zip entry set (minus decided
   deltas), both pass the smoke tests (`--help`, `--version`, run a
   `.tl` script, `--docs`, `--make check`), sizes within an explained
   budget. the two historical silent-payload losses both shipped a
   booting binary — entry-set comparison is the test that catches
   that class.

## exit criteria

release.yml produces both artifacts via `cosmic --make`, the parity
lane has compared them against the Makefile's output for at least one
release cycle, and the artifact carries no repo internals (2 above
resolved, not worked around).
