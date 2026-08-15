# The payload

`cosmic --make build` produces this repo's binary:

```
$ cosmic --make build
make: o/bin/cosmic
build: PASS (374 files, 1 binary)
$ o/bin/cosmic --help | head -1
cosmic-lua: cosmopolitan lua with bundled libraries
```

Building was never the hard half; the *payload* was — what a cosmic
carries beyond its own modules, and where each piece comes from. One
convention answered all of it: **a unit's output directory holds
`embed/` beside `base`** — what the artifact carries, and what it
carries it on. A `cmd/<name>/embed_gen.tl` is handed that directory and
owns the layout inside it, so cosmic's payload is described once, in the
unit that ships it, instead of as a pack list in a makefile. That is
where `tl.lua`, the type tree, the docs index, the embedded `make` and
the version stamp come from.

## Naming a base is correctness, not taste

`embed`'s strip removes a base's zip *entries* without
reclaiming their bytes, so a cosmic built on the running cosmic carries
the previous generation's stripped payload as dead space: the artifact
grew ~3.5 MB per generation — 12.2 → 15.8 → 19.3 MB, measured. A
fixpoint that grows is not a fixpoint. With `base` naming the pinned
`lua`, generation 2 and generation 3 are byte-identical.

## What the payload weighs

Measured against the 6.48 MB release, whose entire zip payload is
0.66 MB compressed (the rest is two-arch native code):

| item | compressed |
|---|---|
| embedded make | ~760 KB |
| `.tl/` cosmic sources | 104 KB |
| `definitions.lua` | 94 KB |
| docs index | 89 KB |
| `tl.lua` | 76 KB |
| types + teal-types | ~110 KB |
| **floor** | ~160 KB |

Stripping recovers ~1.2 MB: it pays for the embedded make and lands a
hello-world slightly under today's binary. **Not a size win beyond
that** — the mass is native code, and the only lever with real weight
is single-arch output, which costs the fat-binary promise. A unit that
names its own `base` strips nothing, because there is nothing on a bare
runtime to strip.

Weight from assets is gone structurally rather than by tuning: D15 makes
shipping opt-in, so a repo full of files *about* a project no longer
rides inside its binary and there is nothing to un-ship.

## The fixpoint

```
$ cosmic --make fetch                        # the Makefile-built cosmic
$ COSMIC_VERSION=stamp cosmic --make build   # …builds gen 2
$ cd <fresh tree> && gen2 --make fetch && gen2 --make build
$ cmp gen2 gen3 && echo identical
identical
```

gen2 type-checks, runs `.tl` scripts, answers `--docs`, prints its
version, and runs `--make check` — on a tree it did not build, with
nothing on the host but itself. `_make/fixpoint_test.tl` gates both
halves in CI.

`--make ci` owns the gate now: fmt, check, example, lint, coverage —
tests run once, instrumented, inside coverage. What is still a workflow
step rather than a verb — enforce, reproducible, offline — the design
puts in phase 4.
