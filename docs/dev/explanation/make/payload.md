# The payload

what cosmic's own artifact carries, where each piece comes from and
what it weighs, for a contributor who changes `cmd/cosmic/embed_gen.tl`
or the strip floor.

`cosmic --make build` at the root produces `o/bin/cosmic` and ends
with a `build: PASS` verdict naming the file count and the one binary.

building is not the hard half; the payload is: what a cosmic carries
beyond its own modules, and where each piece comes from. one
convention answers all of it. a unit's output directory holds
`embed/` beside `base`: what the artifact carries, and what it carries
it on. `cmd/cosmic/embed_gen.tl` is handed that directory and owns the
layout inside it, so cosmic's payload is described once, in the unit
that ships it, instead of as a pack list in a makefile. that is where
`tl.lua`, the type tree, the docs index, the embedded `make` and the
version stamp come from.

## naming a base is correctness, not taste

the embed step removes a base's zip entries without reclaiming their
bytes, so a cosmic built on the running cosmic carries the previous
generation's stripped payload as dead space. measured, that is about
3.5 MB per generation: 12.2 MB, then 15.8, then 19.3. a fixpoint that
grows is not a fixpoint. with `base` naming the pinned `lua`,
generation 2 and generation 3 are byte-identical. the generator also
writes `base-debug` from the pinned `lua-debug`, so one staged payload
yields `o/bin/cosmic` and `o/bin/cosmic-debug`.

## what the payload weighs

measured against a 6.48 MB release, whose entire zip payload is 0.66
MB compressed; the rest is two-arch native code:

| item | compressed |
|---|---|
| embedded make | ~760 KB |
| `.tl/` cosmic sources | 104 KB |
| `definitions.lua` | 94 KB |
| docs index | 89 KB |
| `tl.lua` | 76 KB |
| types + teal-types | ~110 KB |
| **floor** | ~160 KB |

stripping recovers about 1.2 MB: it pays for the embedded make and
lands a hello-world slightly under the release's size. it is not a
size win beyond that. the mass is native code, and the only lever
with real weight is single-arch output, which costs the fat-binary
promise. a unit that names its own `base` strips nothing, because a
bare runtime has nothing to strip.

weight from assets is gone structurally rather than by tuning:
shipping is opt-in, so a repo full of files about a project does not
ride inside its binary, and there is nothing to un-ship.

## the fixpoint

```text
$ cosmic --make fetch                        # the pinned cosmic
$ cosmic --make build                        # …builds gen 2
$ cd <fresh tree> && gen2 --make fetch && gen2 --make build
$ cmp gen2 gen3 && echo identical
identical
```

generation 2 type-checks, runs `.tl` scripts, answers `--docs`, prints
its version and runs `--make check`, on a tree it did not build, with
nothing on the host but itself. `_make/fixpoint_test.tl` gates both
halves; it is two full builds, so it runs only under
`COSMIC_FIXPOINT=1`. CI's `build` lane asserts the same fixpoint with
`cmp`, and the release workflow builds twice for the same reason: the
pinned cosmic builds one from the tree, and that one builds what
ships, so a release is produced by its own code.

`--make ci` owns the gate: fmt, check, example, lint, coverage, with
tests run once, instrumented, inside coverage. what is still a
workflow step rather than a verb (enforce, reproducible, offline) is
listed as planned in [verbs.md](verbs.md).
