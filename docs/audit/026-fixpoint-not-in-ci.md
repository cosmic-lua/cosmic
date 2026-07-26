# 026 — the self-build fixpoint is not gated by any ci lane

severity: medium
type: ci gap
area: `.github/workflows/pr.yml`, `mk/check.mk`

## issue

the branch's headline claim — `cosmic --make build` at the repo root
produces a working cosmic, and gen2 = gen3 byte-identical — is verified
only by hand (recorded in commit 180b0d3's message). in ci:

- the `model` stage (`mk/check.mk:104-124`, listed in `ci_stages`,
  `Makefile:195`) runs only `cosmic --make check`.
- the `reproducible` lane (pr.yml:146-179) double-builds via `bin/make`,
  not via `--make`.
- no lane runs `cosmic --make build` at the root, boots the result, or
  compares generations.

any regression to the artifact pipeline, the payload generator, or the base
selection ships silently; the property that names the branch would rot
first.

## suggested fix

add a ci stage (or extend `model`) that, after the normal build:

1. runs `o/bin/cosmic --make fetch && COSMIC_VERSION=ci o/bin/cosmic --make
   build` (or the bootstrap cosmic, whichever the lane has),
2. smoke-tests the product: `--help`, `--version`, run a `.tl` script,
   `--docs fs`, `--make check` on a fixture,
3. optionally (a separate, slower lane): build gen3 from gen2 in a fresh
   tree and `cmp` the two binaries — the actual fixpoint.

step 2 alone would have caught both historical silent-payload losses (3d's
`tl.lua`, 3h's `_cli/**`) and covers 027's gap at the integration level.

## note

network: step 1 needs `--make fetch` against the real pins unless the lane
pre-seeds `o/3p/**` from the existing `bin/make` fetch — pre-seeding keeps
the lane offline and also exercises the landing-path contract.
