# What remains before `--make` builds cosmic

Measured against a real `--make`-built binary rather than guessed. The
building is done; what remains is the *payload*.

The phase's endpoint is one command producing this repo's binary, with
the checks along the way. **The command produces a binary now** (3h):

```
$ cosmic --make build
make: o/bin/cosmic
build: PASS (359 files, 1 binary)
$ o/bin/cosmic --help | head -1
cosmic-lua: cosmopolitan lua with bundled libraries
```

What remains is not the building but the *payload* — what a cosmic
carries beyond its own modules, and where each piece comes from.
Measured against the binary above rather than guessed:

| # | gap | why it blocks | evidence |
|---|---|---|---|
| ~~1~~ | ~~no entry~~ | **closed in 3h** — `cmd/cosmic/main.tl` | `build: PASS (359 files, 1 binary)` |
| ~~2~~ | ~~`_cli`/`_make` inside `cosmic/`~~ | **closed in 3h** — both at the root | `check: PASS (359 files)` |
| ~~3~~ | ~~`tl.lua` is not in the tree~~ | **closed** — a pin declares `format`/`strip_components` and `fetch` unpacks after verifying; the generator copies `o/3p/tl/tl.lua` into the payload | `.tl` scripts run under the built artifact |
| ~~4~~ | ~~the type tree's location~~ | **closed** — the generator maps `_types/**.d.tl` to `.types/**` | `--check-types` passes under the built artifact |
| ~~5~~ | ~~the docs index~~ | **closed** — the generator calls `cosmic.doc.index` in process; no `regen` verb needed | `--docs fs` answers under the built artifact |
| ~~6~~ | ~~`cosmic.mk` and `make`~~ | **closed** — `cosmic.mk` moved to `embed/cosmic.mk` (committed payload), `make` is copied from the unpacked cosmos zip | the built artifact runs `--make build` |
| ~~7~~ | ~~the version stamp~~ | **closed** — the generator reads the cosmos pin with `cosmic.literal` and takes the cosmic half from `COSMIC_VERSION`; no shell, no `git` | `--version` prints the stamp |
| ~~8~~ | ~~the base is not selectable~~ | **closed, and it was a bug, not a preference** — see below | g2 and g3 are byte-identical |
| 9 | **the artifact ships the repo** | every non-source file is an asset at its relative path, so the repo's own build files ride along. The big one is closed: the make engine moved from `bin/cosmo-make` into `o/`, where nothing generated is ever an input (−751 KB) | remaining asset weight: `docs` 196 KB, `_perf` 152 KB, `_build` 76 KB, `mk` 40 KB |

Items 3–7 were what 3i meant by "the verbs take over", and one
convention closed all five: **a unit's output directory holds `embed/`
beside `base`** — what the artifact carries, and what it carries it on.
A `cmd/<name>/embed.gen.tl` is handed that directory and owns the
layout inside it, so cosmic's payload is described once, in the unit
that ships it, instead of as a pack list in a makefile.

Item 8 turned out not to be the open design question it was recorded
as. Basing on the running cosmic is not merely inelegant: `embed`'s
strip removes a base's zip *entries* without reclaiming their bytes, so
each generation carried the previous one's stripped payload as dead
space and the artifact grew ~3.5 MB per generation — 12.2 → 15.8 →
19.3 MB, measured. A fixpoint that grows is not a fixpoint. With
`base` naming the pinned `lua`, generation 2 and generation 3 are
byte-identical.

Item 9 remains, and carries the open question: a `.cosmicignore` entry
removes a path from the **model**, not only from the artifact, so
ignoring `bin/` also hides it from `check`, `lint` and the coverage
scan — whether "not shipped" and "not seen" should be one knob is
undecided.

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

## The fixpoint

```
$ cosmic --make fetch                       # the Makefile-built cosmic
$ COSMIC_VERSION=stamp cosmic --make build   # …builds gen 2
$ cd <fresh tree> && gen2 --make fetch && gen2 --make build
build: PASS (361 files, 1 binary)
$ cmp gen2 gen3 && echo identical
identical
```

gen2 type-checks, runs `.tl` scripts, answers `--docs`, prints its
version, and runs `--make check` — on a tree it did not build, with
nothing on the host but itself.

Testing along the way is in better shape than building: `--make test`
runs today, and the repo's own tests already take their closures from
the same model (3f). What `bin/make ci` still owns beyond it are the
policy lanes — coverage, enforce, reproducible, offline — which the
design puts in phase 4 as verbs.
