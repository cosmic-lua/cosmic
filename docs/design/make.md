# Design — `cosmic --make`

status: proposal, for review. supersedes the first draft on this branch
(a `go build` lookalike for user projects). the decisions below came out
of a review pass and change the center of gravity: `--make` is not a
wrapper around `--embed`, it is **cosmic's build system**, and this repo
is meant to build with it.

## The shape

Four moving parts:

1. **conventions** — a project is a directory tree. filenames and
   directory positions declare intent; there is no spec file, no
   `rules.tl`, no `cook.mk`.
2. **a constant rules file plus generated facts** — `o/cosmic.mk` ships
   inside the binary and is byte-identical for every project.
   `o/project.mk` is generated and contains *only variable assignments*
   (package dirs, binary names, generator units, 3p pins). no rule is
   ever generated.
3. **cosmic as `SHELL`** — make invokes `cosmic -c '<line>'` for every
   recipe line. lines are whitespace-split argv whose `argv[0]` must be
   a cosmic verb (or the explicit `exec`). cosmic reads the rule's
   grants from target-specific variables and self-restricts before doing
   the work.
4. **the pinned make, embedded** — `make` from the pinned `cosmos.zip`
   ships inside the cosmic binary, extracted to a cache dir on first
   use. one binary, offline, no host toolchain.

```
$ cosmic --make build          # strict check, compile, stage, embed → ./myapp
$ cosmic --make test           # tests, against the staged tree
$ cosmic --make check          # type-check only
$ cosmic --make coverage       # policy verb, not a graph rule
```

## What was decided, and why

| question | decision |
|---|---|
| primary pain | multi-file projects; tests over the code that ships. then rebuild cost/determinism, then discoverability |
| `build` semantics | go semantics: strict type-check + compile + stage + embed. `test` is a separate verb |
| what tests import | the **staged tree** — the exact compiled `.lua` the artifact embeds |
| binaries per project | root `main.tl`, plus `cmd/<name>/main.tl` per artifact |
| artifact contents | root packages + its own `cmd/<name>/**`. `cmd/foo` cannot import `cmd/bar` |
| CLI | `cosmic --make <verb> [path]`, verb first. `--build` stays the recipe driver |
| make's job | sandboxed steps first (bazel-spirit), then staleness, then parallelism |
| rules source | conventions only. no `rules.tl`. cosmic reshapes itself to fit the conventions |
| policy lanes | cosmic **verbs**, not graph rules |
| built-in opinions | none. neutral engine: no automatic version stamp, no automatic doc index |
| generator scope | directory-scoped: a generator's directory is its unit |
| generated outputs | never committed. everything generated lives in `o/` |
| recipe lines | whitespace-split argv, `argv[0]` restricted to cosmic verbs ∪ `exec` |
| make's bytes | embedded in the cosmic release. amends D13 |
| artifact base | stripped by default to a positive keep set. no opt-out for now |
| the floor | compiled cosmic stdlib + certs + zoneinfo + `.args`. everything else stripped, verified by test |
| generated file | written to `o/`, documented, readable |
| generality | constant rules file + generated facts (variables only) |
| staleness | mtime schedules, content decides (write-if-changed at every verb) |

## Project model

The convention vocabulary, in full:

| marker | declares | grants derived |
|---|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format | sources readable, `o/<dir>` writable |
| `*_test.tl` | a test target | staged tree + its own `TEST_TMPDIR` |
| `*_example.tl` | an example target | same |
| `*.d.tl` | type-only; on the include path, never embedded | — |
| `main.tl` at root | the project's binary | staged tree readable, output dir writable |
| `cmd/<name>/main.tl` | one binary per subdirectory | same |
| `<dir>/version.lua` | a pinned 3p dep: fetch → verify sha → extract → stage | network, `o/3p/<dir>` writable |
| `<dir>/` containing a generator | a generation unit (see below) | subtree readable, `o/<dir>` writable |
| `.cosmicignore` | exclusions | — |
| everything else | an asset, embedded at its relative path | — |

Rules:

- **import path = path relative to root, `/`→`.`, extension dropped.**
  `pkg/db.tl` → `require("pkg.db")`; `pkg/init.tl` → `require("pkg")`.
  one rule, identical from source and from inside the artifact.
- **`.lua` sources are first-class** and pass through uncompiled. a
  `foo.tl` beside a `foo.lua` is an error, not a precedence rule.
- **reserved import paths are refused**: `cosmic`, `cosmo`, `tl`,
  `main.user`. the artifact's module path puts the project first, so
  these would shadow the runtime — refused at scan time, with the
  offending file named.
- **`cmd/foo` cannot import `cmd/bar`.** stated by the validator, not
  discovered at runtime.

### Generators

A generation unit is a directory; its inputs are that subtree plus
standing grants (staged `o/3p/**`, the toolchain), and its outputs go to
`o/<dir>/`. Nothing generated is ever committed.

Two consequences, both accepted:

- **two generators in one directory must be split.** `lib/types/` holds
  both `gentype` (cosmo bindings) and `gentl` (Teal compiler API); they
  become `lib/types/cosmo/` and `lib/types/tl/`.
- **invalidation is coarse** — any edit in the subtree reruns the unit.
  for a root-placed doc-index generator, "any source edit" is the
  correct dependency anyway.

Because generated output is never committed, the drift class disappears
entirely: there is no committed copy to drift from, and `gentype_test`'s
byte-comparison ratchet is replaced by "the build produced it." The cost,
recorded as an accepted trade: **you can no longer read `cosmo.*` types
from a fresh clone without building**, and the editor/LSP needs `o/` on
its include path. That pulls against the bare-sandbox story and is the
sharpest edge in this design.

## Artifact model

### Layout

The artifact is assembled from the **effective tree** — sources overlaid
with `o/` outputs — through one rule:

```
package module, import path P   →  /zip/.lua/P.lua
asset at relative path R        →  /zip/R
entry (main.tl | cmd/<n>/main)  →  /zip/main.user.lua behind the wrapper
```

That single rule reproduces cosmic's own current layout: compiled stdlib
at `.lua/cosmic/`, `sys/help.md` at `sys/`, skills at `skills/`, the
staged `tl.lua` (a 3p-provided module) at `.lua/tl.lua`, the generated
doc index and types at their `o/`-mirrored positions. **`pack_copies`
disappears** — the layout stops being enumerated and becomes derived.

Open item: this moves user artifacts from `/zip/?.lua` to
`/zip/.lua/?.lua`, changing the `#687/#690` wrapper's `package.path`. A
deliberate break, cheap now, and it buys one layout rule for every
artifact including cosmic's own.

### Stripping

The base is **always stripped to a positive keep set**; anything above
the floor is the project's own files. There is no `--keep` flag.

**Floor:** compiled cosmic stdlib (`.lua/cosmic/**`), TLS roots
(`usr/share/ssl/root/*.pem`), zoneinfo, `.args`.

**Stripped:** the embedded make, `.lua/tl.lua`, `.lua/types/**`,
`.lua/teal-types/**`, `.tl/**`, `.docs/**`, `skills/**`, `sys/**`,
`.lua/definitions.lua`, `.lua/cosmo/**`.

This is what makes cosmic buildable by `--make` without an exception:
cosmic's artifact carries `tl.lua`, its types, its docs index, and its
embedded make because **its own tree provides them** — from its `3p`
pins and its own generators — not because the base kept them. Any user
wanting Teal at runtime vendors it the same way. It is no longer free.

Measured sizes (from the current 6.48 MB `cosmic-lua` release, whose
entire zip payload is 0.66 MB compressed — the other ~5.8 MB is
two-architecture native code):

| item | compressed |
|---|---|
| embedded make (new) | ~760 KB |
| `.tl/` cosmic sources | 104 KB |
| `.lua/definitions.lua` | 94 KB |
| `.docs/` index | 89 KB |
| `.lua/tl.lua` | 76 KB |
| types + teal-types | ~110 KB |
| **floor** (stdlib + certs + zoneinfo) | ~160 KB |

Stripping recovers ~1.2 MB, which pays for the embedded make and lands a
hello-world artifact slightly under today's binary. **Stripping is not a
size win beyond that** — the mass is native code, and the only lever
with real weight is single-arch output, a separate feature that costs
the fat-binary promise.

The risk this creates is a `cosmo.*` binding that lazily requires a
stripped `.lua/cosmo/**` helper. Mitigation is a gate, not a guess: a
**stripped-artifact test lane** that runs the stdlib's own tests inside a
stripped artifact.

### Reproducibility

Two builds of the same tree, in different directories, at different
times, produce byte-identical artifacts. Entries carry a fixed mtime
(`SOURCE_DATE_EPOCH`, else the DOS floor 315532800) rather than the
staging file's; `AddOptions.mtime` already exists in the binding and is
simply not plumbed through `embed.run` today. Gate: build the same
fixture twice into different paths, compare sha256.

## Engine

### Constant rules, generated facts

`o/cosmic.mk` ships in the binary, byte-identical everywhere. Discovery
inside it uses `$(wildcard)` and the `rwildcard` foreach-recursion idiom
— builtins only, no `$(shell)`. `o/project.mk` is generated by cosmic
and contains only variable assignments.

The codegen surface therefore shrinks to "emit a list of variables," and
cosmic keeps discovery *and validation* in Teal, where errors can be good.
This repo's makefile ratchets collapse from "statically scan generated
recipe text" to "one file that does not change."

Cost: a stale `o/project.mk` if someone runs `make -f o/cosmic.mk`
directly. `cosmic --make` is the entry point and regenerating facts is
one tree walk with write-if-changed.

### Cosmic as `SHELL`

`SHELL := cosmic`. Cosmic grows `-c '<line>'`, which means make's default
`.SHELLFLAGS` works unchanged. A line is:

- whitespace-split into argv — no quoting, no expansion, no pipes, no
  redirects (this is already the repo's no-shell discipline, made
  official rather than enforced by a ratchet);
- `argv[0]` must be a **cosmic verb** (`copy`, `link`, `compile`,
  `capture`, `tee`, `list`, `remove`, `require-*`, `verdict`, …) or the
  explicit `exec`, which is a visible, greppable act.

Two properties fall out:

- **the build's entire capability surface is enumerable.** the recipe
  vocabulary is a closed, documented set; the ratchet that scans recipe
  text for shell metacharacters becomes unnecessary.
- **sandboxing stops depending on fork-specific syntax.** grants ride in
  target- and pattern-specific variables (`COSMIC_UNVEIL = $^`,
  `COSMIC_PLEDGE = …`, plain GNU make), and *cosmic* self-restricts
  before doing the work. `.PLEDGE`/`.UNVEIL` rule attributes become
  optional rather than load-bearing.

Grants are derived, not written: prerequisites readable, target directory
writable, plus the standing base. A rule declares nothing.

Cost to watch: cosmic is spawned once per recipe line. That is already
true of this repo's recipes (each execs the pinned bootstrap), so it is
not a regression — but under `-j` on a large graph it is the thing that
shows up in wall-clock, which argues for keeping per-line work small and
the startup path fast.

### Staleness

Mtime schedules; content decides. Make picks candidates by mtime, and
every verb writes its output **only when the bytes change** — the
existing `run_into` cmp/mv contract, generalized to every step by virtue
of cosmic being the shell. A no-op step does not touch its output, so
the non-change propagates and downstream stays fresh.

An action cache keyed on `(argv + input hashes)` is the natural next step
and is deliberately deferred until profiling shows spawn-and-check
dominating.

## Verbs

**Graph verbs** — lower to make and run the graph:

```
build [path]    strict check → compile → stage → embed
test  [path]    build the stage, run *_test.tl against it, verdict line
check [path]    strict type-check only
fmt   [path]    --check-format (--fix to rewrite)
run   [path]    build, then exec the artifact with remaining argv
regen [path]    run generation units
clean           remove o/
```

**Policy verbs** — orchestration over the graph, never graph rules
(this is what keeps them from needing an escape hatch):

```
ci              format + check + test + example + lint + coverage
coverage        tests with line coverage + ratchet
enforce         sandbox-enforced lane
reproducible    double-build + compare
offline         no-network lane
```

Every verb ends in a machine-readable verdict line and an exit code,
per the existing "never launder a gate through a pipe" rule. `test`
keeps `testrun`'s `.got`/`.out`/`.err` contract and `status_of`
(0 pass / 2 skip / other fail) unchanged.

## Trust root: amending D13 and D14

**D13** currently rejects "shipping make inside the cosmic release
binary (entangles the two release cycles for no reduction in what must
be trusted — one fetcher, two pins is the achievable minimum)." That
reasoning is sound *for this repo's build*, where both pins are already
in hand. It does not survive the user case: someone holding one cosmic
binary in a bare sandbox cannot build anything unless make is inside it,
and for them embedding collapses two pins to one.

Amended chain: **kernel → committed fetcher → one pin → everything.**
`bin/make` becomes a fetcher for a single artifact. The cost D13 names —
entangled release cycles — is real and bounded: cosmic already pins
`cosmos.zip` for its base binary, so it already moves when cosmopolitan
moves.

**D14** ("no self-hosting: pinned make is permanent") is *not*
contradicted — it is completed. D14 rejects a cosmic-native **graph
executor** and says the endgame "shrinks what make means — a job
execution system and dependency graph, nothing else." That is exactly
this: make keeps the graph, the jobserver, and staleness scheduling;
cosmic supplies the graph's content, every recipe's semantics, and the
sandbox. D14's rejection of "driving the build from a cosmic script that
shells out to make as a library" does need revisiting, since `cosmic
--make` drives make — the distinction being that make is still the
execution engine, not a subroutine.

## What this repo looks like afterward

`cook.mk` and `mk/*.mk` disappear, replaced by conventions:

| today | becomes |
|---|---|
| `cosmic_srcs`/`_tl`/`_tests` wildcards | package convention |
| `pack_copies` enumeration | the artifact layout rule |
| `$(cosmos_staged)`, `$(tl_staged)` | `version.lua` convention (already exists) |
| `gentype`/`gentl` rules | generation units, split into two directories |
| doc index rule | a generation unit at the root |
| version stamp rule | a generation unit (its `.git` read stays an opt-out) |
| `.PLEDGE`/`.UNVEIL`/`.ENV` annotations | derived grants, enforced by cosmic-as-SHELL |
| `.SANDBOXED`, hostx, recipe-scan ratchets | mostly unnecessary; the vocabulary is closed |
| coverage/enforce/reproducible/offline lanes | policy verbs |

`-include cosmic.mk` is the migration bridge: families move onto
conventions one at a time while the rest stay in make syntax. The bridge
is not part of the end state.

What stays bespoke, honestly: the `git describe` version stamp (a
deliberate host dependency with its own sandbox opt-out), and the
first-fetch shell in `bin/make`.

## Gates for the change itself

- fixture projects: single-binary, `cmd/`-multi-binary, `.lua`-only,
  mixed, assets, `.cosmicignore` — each built and *run*, asserting output
- reproducibility: double-build into different paths, compare sha256
- stripped-artifact lane: the stdlib's own tests, run inside a stripped
  artifact (this is what makes the floor safe to shrink)
- sandbox canary under cosmic-as-`SHELL`, proving derived grants are
  enforced on a Landlock host, and denied-access failures are loud
- verb-vocabulary ratchet: the closed set of recipe verbs is enumerated
  and cannot grow silently
- `o/`-only check: no generated file lands in the tree
- validator errors: reserved import path, `cmd/foo`→`cmd/bar` import,
  `foo.tl`+`foo.lua` collision, missing entry — each with the message
  asserted, since these are the errors a fresh agent will hit first

## Phasing

1. **`-c` shell mode.** cosmic gains `-c`, the closed verb vocabulary,
   and grant self-restriction from target-specific variables. this repo
   switches `SHELL := cosmic` with `cook.mk` otherwise untouched. gate:
   the existing suite, plus the sandbox canary.
2. **User-facing `--make`.** constant rules file + facts generator;
   `build`/`test`/`check`/`fmt`/`run`/`clean` over the conventions;
   artifact stripping, embedded make, reproducibility. **this is the
   phase that answers the original ask** — a tree of `.tl`/`.lua` plus
   tests becomes an artifact — and it ships independently of anything
   below.
3. **Dogfood.** migrate this repo's families onto conventions behind
   `-include cosmic.mk`, one at a time: packages, tests/examples, 3p,
   generators (split `lib/types`, move outputs to `o/`), the pack.
4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; `--make explain`; single-arch
   artifacts.

## Open items

1. **artifact module path** moves to `/zip/.lua/?.lua` (above). needs a
   yes/no — it is the one deliberate break to the existing `--embed`
   contract.
2. **generator granularity** is recorded as directory-scoped. file-scoped
   (`x.gen.tl` owns `x.lua` or `x/`) remains a live alternative that
   avoids splitting `lib/types`; say if you want it.
3. **`cosmic -c` spawn cost** under `-j` on a large graph is unmeasured.
   phase 1 should report a number before phase 3 commits this repo to it.
4. **stripped-floor risk**: `.lua/cosmo/**` may back a lazily-required
   binding. the stripped-artifact lane is the gate; if something needs to
   come back, it comes back with a test naming it.
5. **`--make` as a flag name** survives even though nothing makes a
   Makefile anymore. `--build` is taken by the recipe driver. no better
   name proposed.
