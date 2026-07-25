# Design — `cosmic --make`

status: proposal, for review. three review rounds are folded in; the
decision tables are the record.

`--make` is **cosmic's build system**, not a wrapper around `--embed`.
This repo is meant to build with it.

## The shape

1. **conventions** — a project is a directory tree. filenames and
   directory positions declare intent. no spec file, no `rules.tl`, no
   `cook.mk`.
2. **a constant rules file plus generated facts** — `o/cosmic.mk` ships
   inside the binary, byte-identical for every project. `o/project.mk`
   is generated and holds *only variable assignments*. no rule is ever
   generated.
3. **cosmic as `SHELL`** — make invokes `cosmic -c '<line>'` for every
   recipe line. lines are whitespace-split argv whose `argv[0]` must be
   a cosmic verb, or `exec` — which resolves **only to pinned bytes**.
4. **the pinned make, embedded** — extracted to a cache dir on first
   use. one binary, offline, no host toolchain.

```
$ cosmic --make build          # strict check, compile, stage, embed → o/bin/myapp
$ cosmic --make test           # tests, fenced, against the staged tree
$ cosmic --make fetch          # the only verb that touches the network
$ cosmic --make ci             # fixed order, stages gated by what the project has
```

Two sentences carry most of the design:

- **inputs = grants = your staged subtree.** it defines what a generator
  may read, what a test may read, and what the sandbox permits.
  corollary: *put it where its inputs are.*
- **a build runs only bytes you pinned, and only your code without a
  socket.** pins are data, `fetch` is the only networked verb, `exec`
  resolves only to pinned artifacts. the entire external surface —
  endpoints and executables — is enumerable from committed files.

## Decisions

| question | decision |
|---|---|
| primary pain | multi-file projects; tests over the code that ships. then rebuild cost/determinism, then discoverability |
| `build` semantics | strict type-check + compile + stage + embed. `test` is a separate verb |
| what tests import | the **staged tree** — the exact compiled `.lua` the artifact embeds |
| binaries per project | root `main.tl`, plus `cmd/<name>/main.tl` per artifact |
| artifact contents | root packages + its own `cmd/<name>/**`. `cmd/foo` cannot import `cmd/bar` |
| artifact output | `o/bin/<name>` |
| CLI | `cosmic --make <verb> [paths…]`, verb first |
| rules source | conventions only. no `rules.tl`. cosmic reshapes itself to fit |
| policy lanes | cosmic **verbs**, not graph rules |
| built-in opinions | none. no automatic version stamp, no automatic doc index |
| generated outputs | never committed; everything generated lives in `o/` |
| generator units | directory-scoped; one directory per generated asset |
| generator inputs | its containing subtree = its grants. reads outside are **denied**, not stale |
| enforcement | Landlock where available **plus** portable in-process gating |
| project root | cwd, with a loud guard if an ancestor also looks like a project |
| module root | the project root |
| public vs private | `_`-prefixed directory = importable only from within its container |
| this repo's layout | `cosmic/` is the public API; `_cli/`, `_build/`, `_make/`, `_types/`, `_perf/`, `_docs/` at root; `cmd/`; `3p/` |
| artifact layout | `/zip/<import path>.lua`, assets at `/zip/<rel>` |
| `testdata/` | excluded from artifacts (that is its only job) |
| paths | filenames with spaces or shell metacharacters are a validator error |
| network | only under `--make fetch`. **no project code ever runs with a socket** |
| pins | `*.pin.tl` — Teal, statically extracted from a literal, never executed |
| `exec` | resolves only to pinned/staged bytes under `o/`. never `PATH` |
| version stamp | committed data (`version.tl`) plus an environment override |
| recipe lines | whitespace-split argv; `argv[0]` ∈ closed verb set ∪ `exec` |
| `-c` vs `--build` | `-c` wins; `--build` retired across two release cycles |
| make's bytes | embedded in the cosmic release. amends D13 |
| provisioning | `bin/cosmic` fetches one pin here; **downstream projects commit their cosmic** |
| artifact base | stripped to a positive floor. no opt-out |
| the floor | compiled `cosmic/**` + certs + zoneinfo + `.args`; verified by test |
| generated makefile | written to `o/`, documented, readable |
| generality | constant rules + generated facts (variables only) |
| staleness | mtime schedules, content decides (write-if-changed everywhere) |
| parallelism | everything parallel; spawn cost is a budget, not an excuse |
| test isolation | writes `TEST_TMPDIR` only; reads = staged subtree + staged modules |
| test selection | paths (several), expanded by the caller's shell. no filter flag |
| `ci` | fixed order, each stage gated by whether the project has material for it |

## Project model

| marker | declares | grants |
|---|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format | sources readable, `o/<dir>` writable |
| `_<dir>/` | internal: importable only from within its container | — |
| `*_test.tl` | a test target | staged subtree readable, `TEST_TMPDIR` writable |
| `*_example.tl` | an example target | same |
| `testdata/` | test fixtures; **never embedded** | readable (it is in the subtree) |
| `*.d.tl` | type-only; include path, never embedded | — |
| `main.tl` at root | the project's binary | staged tree readable, `o/bin` writable |
| `cmd/<name>/main.tl` | one binary per subdirectory | same |
| `<dir>/*.pin.tl` | a pinned external asset | network **only** under `fetch` |
| `<dir>/*.gen.tl` | a generation unit | its subtree readable, `o/<dir>` writable |
| `.cosmicignore` | exclusions | — |
| everything else | an asset, embedded at its relative path | — |

- **import path = path relative to root**, `/`→`.`, extension dropped.
  `pkg/db.tl` → `require("pkg.db")`; `pkg/init.tl` → `require("pkg")`.
- **the project root is the module root.**
- **root discovery: cwd.** an explicit path overrides. if an ancestor
  also looks like a project, `--make` **refuses**, naming the likely
  root and the exact command. every run prints `make: root=<path>`.
- **`_` marks internal.** a directory whose name starts with `_` is
  importable only from within the directory containing it — so root
  `_cli/` is project-wide internal, `cosmic/_x/` is internal to
  `cosmic/`. The validator enforces it. Three things then derive from
  position instead of a manifest: the public API surface, what the docs
  generator documents, and the artifact floor. `public.tl` is deleted.
- **reserved import paths refused**: `cosmic`, `cosmo`, `tl`,
  `main.user`.
- **`cmd/foo` cannot import `cmd/bar`.**
- **filenames with spaces or shell metacharacters are refused**, so
  recipe splitting is total and quoting never exists. Accepted cost: a
  legitimate `my notes.tl` is rejected, by name.
- **`.lua` sources are first-class**; `foo.tl` beside `foo.lua` is an
  error, not a precedence rule.

### Generators

A generation unit is a directory holding a `*.gen.tl`; one directory per
generated asset. **Inputs are its containing subtree, and its grants are
exactly that set** — so a generator reading outside its scope gets a
denied read, not a silently stale output. Outputs go to `o/<dir>/`.

Enforcement is doubled because `unveil()` no-ops off Landlock: kernel
enforcement where available, plus in-process gating of `cosmic.fs`/`io`
for the generator's duration, so the rule holds on macOS and Windows and
the developer meets it where they wrote it. Same message from both.

Nothing generated is ever committed, so the drift class disappears —
there is no committed copy to drift from. Accepted cost: **`cosmo.*`
types can no longer be read from a fresh clone without building**, and
editors need `o/` on the include path. This is the sharpest edge here.

### External assets and execution

Fetching is **not** a generator. A `*.pin.tl` is Teal data — a single
`return { … }` literal, type-checked, **statically extracted from the
AST and never executed**. `--make fetch` downloads and verifies; `build`
never opens a socket.

`exec` resolves only to pinned or staged bytes under `o/` — never a
`PATH` lookup. A project may run a tool it pinned; it cannot run
whatever happens to be installed.

Together: *building an untrusted repo cannot phone home, and cannot run
a host binary.* Both halves of the external surface are greppable.

Corollary, and the reason the version stamp is data: `git describe` is
not available to a build. `version.tl` is committed and bumped by
release automation, with an environment override for CI, and a `dev`
fallback. No host tool, no `.git` read.

## Artifact model

### Layout

Assembled from the **effective tree** — sources overlaid with `o/`
outputs — through one rule:

```
package module, import path P  →  /zip/P.lua
asset at relative path R       →  /zip/R
entry                          →  /zip/main.user.lua behind the wrapper
```

The zip root *is* the module root, so "path relative to root = import
path" holds inside the artifact too. `pack_copies` disappears; the
layout is derived, not enumerated. Cosmic's own payload moves with it
(`/zip/.lua/cosmic/*` → `/zip/cosmic/*`, `.lua/tl.lua` → `tl.lua`),
touching the searcher's include dirs — contained, and it lands in phase
3 when the pack rule is rewritten anyway.

### Stripping

The base is **always stripped to a positive floor**; anything above it
is the project's own files. There is no `--keep`.

**Floor:** compiled `cosmic/**` (the public modules — derived, since
`_` marks the rest), TLS roots, zoneinfo, `.args`.
**Stripped:** the embedded make, `tl.lua`, types, teal-types, cosmic's
`.tl` sources, docs index, skills, `sys/`, `definitions.lua`,
`.lua/cosmo/**`.

This is what lets cosmic build itself with no exception: its artifact
carries `tl.lua`, types, docs, and make because **its own tree provides
them** — from its pins and generators — not because the base kept them.
Any user wanting Teal at runtime vendors it the same way.

Measured against the 6.48 MB release, whose entire zip payload is
0.66 MB compressed (the rest is two-arch native code):

| item | compressed |
|---|---|
| embedded make (new) | ~760 KB |
| `.tl/` cosmic sources | 104 KB |
| `definitions.lua` | 94 KB |
| docs index | 89 KB |
| `tl.lua` | 76 KB |
| types + teal-types | ~110 KB |
| **floor** | ~160 KB |

Stripping recovers ~1.2 MB: it pays for the embedded make and lands a
hello-world slightly under today's binary. **Not a size win beyond
that** — the mass is native code, and the only lever with real weight is
single-arch output, which costs the fat-binary promise.

Risk: a `cosmo.*` binding lazily requiring a stripped `.lua/cosmo/**`
helper. Gate: a **stripped-artifact test lane** running the stdlib's own
tests inside a stripped artifact.

### Reproducibility

Entries carry a fixed mtime (`SOURCE_DATE_EPOCH`, else the DOS floor
315532800) rather than the staging file's; `AddOptions.mtime` exists in
the binding and is not plumbed through `embed.run` today. Gate: build
the same fixture twice into different paths, compare sha256.

## Engine

### Constant rules, generated facts

`o/cosmic.mk` ships in the binary, byte-identical everywhere; discovery
uses `$(wildcard)` and `rwildcard` foreach-recursion — builtins only, no
`$(shell)`. `o/project.mk` is generated and contains only variable
assignments, so codegen shrinks to "emit a list of variables" while
discovery and validation stay in Teal where errors can be good. This
repo's makefile ratchets collapse from "scan generated recipe text" to
"one file that does not change."

### Cosmic as `SHELL`

`SHELL := cosmic`; cosmic grows `-c '<line>'`, so make's default
`.SHELLFLAGS` works unchanged. A line is whitespace-split argv — no
quoting, no expansion, no pipes, no redirects — whose `argv[0]` is a
cosmic verb or `exec`.

- **the capability surface is enumerable**; the metacharacter-scanning
  ratchet becomes unnecessary.
- **sandboxing stops depending on fork-specific syntax.** grants ride in
  target- and pattern-specific variables (`COSMIC_UNVEIL = $^`, plain
  GNU make) and cosmic self-restricts. `.PLEDGE`/`.UNVEIL` attributes
  become optional rather than load-bearing.

`--build` and `-c` are the same dispatcher; `-c` wins. The ordering is a
constraint, not a preference: **`-c` must ship in a release before this
repo can set `SHELL := cosmic`**, because recipes run the pinned older
bootstrap. Sequence: add `-c` → release → bump the pin → switch `SHELL`
and migrate recipes → remove `--build` the following release.

### Staleness and parallelism

Mtime schedules; content decides. Every verb writes its output only when
the bytes change — the existing `run_into` contract, generalized by
cosmic owning the shell. A no-op step doesn't touch its output, so
non-changes stop propagating.

**Everything is parallel** (`-j$(nproc)`, honoring an inherited
jobserver and an explicit `--jobs`). Cosmic is spawned once per recipe
line; that is a **budget to hold, not a reason to serialize** — phase 1
reports the number and optimizes startup if it isn't small.
Parallel-by-default is defensible only because isolation is structural.

An action cache keyed on `(argv + input hashes)` is deferred until
profiling justifies it.

## Tests

Same rule as generators: **inputs = grants = your staged subtree.**

- **writes:** `TEST_TMPDIR` only; anything else is a denial, on the
  author's machine, at the moment it happens.
- **reads:** the staged subtree rooted at the test's own directory, plus
  the staged module tree it imports. Other packages' sources, `$HOME`,
  and the live tree are denied.
- **one shared stage** per run, so reads are of an immutable snapshot —
  removing the read-a-file-another-test-is-writing class and costing one
  stage, not one per test. Immutability is enforced twice: Landlock
  restrictions are inherited across `exec`, so a test's children are
  fenced too; and the stage is chmodded read-only (`0444`/`0555`) so the
  guarantee survives on hosts without Landlock, where the in-process
  gate covers a test's own IO but **not** what it spawns.
- fixtures need no special grant — anything in the test's subtree is
  readable. `testdata/` exists solely to keep fixtures **out of the
  artifact**.
- ambient environment is redirected into the test's directory
  (`TMPDIR`, `HOME`, `XDG_*`, cwd), with `TEST_SRCDIR` pointing at the
  staged subtree.
- `testrun`'s `.got`/`.out`/`.err` contract and `status_of` (0 pass /
  2 skip / other fail) are unchanged.
- **selection is by path**, several accepted, globbed by the caller's
  shell (`cosmic --make test cosmic/*/db_test.tl`). No filter flag —
  the shell already does that better. Selection changes which tests
  run, never what gets staged: a partial stage would resolve differently
  than a full one.

**Ports remain a known, documented gap** — fencing can't see them.

Consequence here: ratchet tests that read the live tree
(`makefile_ratchet_test.tl`, the cast and coverage ratchets) **move to
where their inputs are** — the project root, whose subtree is the whole
staged tree.

## Verbs

**Graph verbs:**

```
build [paths…]  strict check → compile → stage → embed → o/bin/<name>
test  [paths…]  build the stage, run *_test.tl fenced against it
check [paths…]  strict type-check only
fmt   [paths…]  --check-format (--fix to rewrite)
run   [path]    build, then exec the artifact with remaining argv
regen [paths…]  run generation units
fetch [paths…]  resolve *.pin.tl — the only verb with network
clean           remove o/
```

**Policy verbs** — orchestration over the graph, never graph rules:

```
ci              format → check → test → example → lint → coverage
coverage        tests with line coverage + ratchet
enforce         sandbox-enforced lane
reproducible    double-build + compare
offline         no-network lane, asserted against the pins
```

`ci` is a fixed order with **each stage gated by whether the project has
material for it** — no tests, no test stage; no committed coverage
baseline, no ratchet. Zero configuration, and a fresh project doesn't
fail on a stage that had nothing to do. (A coverage baseline is *input*
data, so it stays committed; only generated things are banned from the
tree.)

Every verb ends in a machine-readable verdict line and an exit code.

## Provisioning and the trust root

**This repo:** `bin/cosmic` — POSIX sh, one job: fetch the pinned cosmic
(pin in `bootstrap/cosmic.pin.tl`) and exec it. `bin/cosmic --make ci`.
Since make is embedded, the chain is **kernel → committed fetcher → one
pin → everything**, down from two pins.

**Downstream projects: commit the binary.** A fat APE in the repo means
`./cosmic --make ci` works from a fresh clone with **zero network and no
shell at all** — the strongest possible version of the bare-sandbox
story, and the right default for a repo pinning a stable toolchain.
Cosmic itself keeps a fetcher because it bumps its own toolchain
constantly and would bloat fastest.

**D13** is amended twice: make ships inside the release (its rejection
reasoned from this repo, where both pins are already in hand — it does
not survive the user case), and vendoring is *recommended downstream*
while rejected here, which is a sharper rule than the blanket one.

**D14** is completed, not contradicted: it rejects a cosmic-native
*graph executor* and says the endgame shrinks make to "a job execution
system and dependency graph, nothing else." Exactly this. Its rejection
of "driving the build from a cosmic script that shells out to make"
needs revisiting — make remains the engine, not a subroutine.

## Worked examples

**This repo, after migration**

```
bin/cosmic                  fetch pinned cosmic, exec it
cosmic/                     PUBLIC API — this directory is the interface
  fs/init.tl  fs/path.tl  fs/fs_test.tl
  json.tl  json_test.tl  json_example.tl
  net/  sqlite/  fetch/  …
_cli/  main.tl  help.tl  searcher.tl  version.tl
_build/  _make/  _perf/
_types/cosmo/cosmo.gen.tl   → o/_types/cosmo/*.d.tl
_types/tl/tl.gen.tl         → o/_types/tl/tl.d.tl
_docs/index/index.lua.gen.tl → o/_docs/index/index.lua
cmd/cosmic/main.tl          the binary → o/bin/cosmic
3p/tl/tl.pin.tl  3p/cosmos/cosmos.pin.tl
bootstrap/cosmic.pin.tl
sys/  skills/  docs/  .github/
o/                          everything generated
```

**A single-binary user project**

```
myapp/
  main.tl                   → o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl          reads staged db/**, writes TEST_TMPDIR
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  schema.sql                asset
  3p/lpeg/lpeg.pin.tl       cosmic --make fetch
```

```
o/bin/myapp  →  /zip/main.lua          generated wrapper
                /zip/main.user.lua     compiled main.tl
                /zip/config.lua
                /zip/db/init.lua  /zip/db/query.lua
                /zip/_internal/util.lua
                /zip/schema.sql
                /zip/cosmic/**         the floor
                /zip/usr/share/ssl/**  the floor
```

**Multi-binary**

```
tools/
  cmd/fetchit/main.tl
  cmd/servit/main.tl  cmd/servit/routes.tl
  shared/http.tl            require("shared.http")
  _internal/log.tl
```

`o/bin/fetchit` embeds `shared/**`, `_internal/**`, `cmd/fetchit/**`;
`o/bin/servit` the same roots plus `cmd/servit/**`. Neither can import
the other's `cmd` directory.

## What this repo looks like afterward

| today | becomes |
|---|---|
| `cook.mk`, `mk/*.mk` | conventions |
| `lib/cosmic/`, `lib/build/`, … | `cosmic/`, `_build/`, … (root = module root) |
| `public.tl` | the `_` prefix; the tree is the manifest |
| `pack_copies` enumeration | the artifact layout rule |
| `3p/*/version.lua` | `*.pin.tl`, statically extracted |
| `gentype`/`gentl` rules | generation units, one directory each |
| doc index, version stamp | a generation unit; committed data + env |
| `.PLEDGE`/`.UNVEIL`/`.ENV` | derived grants, enforced by cosmic-as-`SHELL` |
| `.SANDBOXED`, hostx, recipe-scan ratchets | mostly unnecessary; the vocabulary is closed |
| ratchet tests reading the tree | moved to the root, where their inputs are |
| coverage/enforce/reproducible/offline | policy verbs |
| `bin/make ci` | `bin/cosmic --make ci` |

`-include cosmic.mk` is the migration bridge only. What stays bespoke:
the first-fetch shell in `bin/cosmic`.

## Gates for the change itself

- fixture projects — single-binary, `cmd/` multi-binary, `.lua`-only,
  mixed, assets, `testdata/`, `.cosmicignore` — each built and *run*
- reproducibility: double-build into different paths, compare sha256
- stripped-artifact lane: the stdlib's own tests inside a stripped
  artifact (what makes the floor safe to shrink)
- sandbox canary under cosmic-as-`SHELL`, on Landlock **and** via the
  in-process gate, proving both produce the same denial
- fence tests: a generator reading outside its subtree; a test writing
  outside `TEST_TMPDIR`; a test's *spawned child* attempting the same
- stage immutability: read-only modes survive a run; optional CI-only
  before/after hash to name a culprit
- `exec` refuses an unpinned binary; `fetch` is the only verb that can
  open a socket (asserted, not assumed)
- pin extraction: a `*.pin.tl` that is not a literal is rejected, and a
  pin is never executed
- `testdata/` never appears in an artifact
- `_` enforcement: importing `_x` from outside its container fails
- `o/`-only check: no generated file lands in the tree
- validator messages asserted: reserved import path,
  `cmd/foo`→`cmd/bar`, `foo.tl`+`foo.lua`, missing entry, space in
  filename, ambiguous root, internal import
- spawn-cost budget: `cosmic -c` under `-j`, reported in phase 1

## Phasing

1. **`-c` shell mode.** the closed verb vocabulary, `exec`'s
   pinned-only resolution, grant self-restriction from target-specific
   variables, the portable in-process gate. this repo keeps `cook.mk`
   and switches `SHELL` only *after* the release that ships `-c`.
   reports the spawn-cost number.
2. **User-facing `--make`.** constant rules + facts generator;
   `build`/`test`/`check`/`fmt`/`run`/`fetch`/`clean` over the
   conventions; fenced tests; artifact stripping; embedded make;
   reproducibility. **this phase answers the original ask** and ships
   independently of everything below.
3. **Dogfood.** flatten to root = module root, introduce `_` internals,
   migrate families behind `-include cosmic.mk`: packages,
   tests/examples, pins, generators, the pack. `bin/make` → `bin/cosmic`.
4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; port isolation; `--make
   explain`; single-arch artifacts.

## Open items

1. **`--make` as a name** survives though nothing makes a Makefile.
   `--build` frees up after phase 1 — worth deciding then whether to
   take it.
2. **stripped-floor risk**: `.lua/cosmo/**` may back a lazily-required
   binding. the stripped-artifact lane is the gate; anything that comes
   back comes back with a test naming it.
3. **ports** remain unfenced; `TEST_PORT_BASE` or a `net` helper later.
4. **spawn cost** under `-j` is unmeasured — a phase 1 deliverable, and
   the one number that could force a redesign of the recipe granularity.
