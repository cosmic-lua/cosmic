# 027 — `cmd/cosmic/embed.gen.tl` has no payload test

severity: medium
type: test gap
area: `cmd/cosmic/embed.gen.tl`, `_make/generate_test.tl`

## issue

`_make/generate_test.tl` exercises the embed.gen *mechanism* on synthetic
fixtures only. the real payload generator — the 331-line
`cmd/cosmic/embed.gen.tl` that assembles `.tl/**` sources, `.types/**`,
`.docs/index.lua`, `tl.lua`, `make`, the version stamp, and `base` — has no
test at all. a payload regression (a renamed source dir, a changed pin
landing path, a filter that starts excluding a group) produces a binary
that builds, boots, and fails only when someone first exercises the missing
piece.

this is the exact hazard the branch's own logs record biting **twice**: 3d
lost `tl.lua` and the type tree, 3h lost every compiled `_cli/**` and
`_make/**` module — both times "the binary built, ran, and failed only when
something first required" the lost payload.

## where

- `cmd/cosmic/embed.gen.tl` — untested.
- `_make/generate_test.tl` — synthetic-fixture coverage only.

## suggested fix

a test that runs the real generator against the real tree (it needs the
pins' landing paths; skip with status 2 when `o/3p/**` is absent, mirroring
the graph tests) and asserts the presence of each contract entry in the
output directory: `embed/tl.lua`, `embed/make`, `embed/.types/cosmo.d.tl`,
`embed/.docs/index.lua`, `embed/cosmic/_version.lua`, at least one
`embed/.tl/**` source, and `base`. a manifest-style assertion (sorted
top-level listing compared against a committed expectation) makes additions
loud too.

integration-level coverage of the same property belongs in the fixpoint
lane (026); this test is the fast, local half.
