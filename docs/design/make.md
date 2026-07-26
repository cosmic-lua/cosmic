# Design — `cosmic --make`

status: three review rounds folded in; the decision tables are the
record. delivery is in [make-plan.md](make-plan.md); what each landed
slice settled is in make-log.md, make-log-dogfood.md and
make-log-selfbuild.md. `--make` is **cosmic's build system**, not a
wrapper around `--embed`, and this repo builds with it.

## What this replaced

`--make [dir] [target]` scanned for `*.tl`, classified by suffix,
emitted a Makefile and ran make on it. Three things were wrong with it,
and they are what this design addresses: it **needed a host make**, it
**produced build files, not builds**, and its **project model was a
flat scan** — no packages, no entry point, no artifact, no notion of
what ships. Dropped whole in 2a; the fuller account is in
[make-log.md](make-log.md).

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
4. **the pinned make, embedded** — extracted to `o/make` on first use.
   one binary, offline, no host toolchain. (Landed in 2e; costs ~765 KB
   on the release, uncompensated — see make-plan.md.)

```
$ cosmic --make build          # strict check, compile, stage, embed → o/bin/myapp
$ cosmic --make test           # tests, fenced, against the staged tree
$ cosmic --make fetch          # the only verb that touches the network
$ cosmic --make ci             # PLANNED: fixed order, stages gated by material
```

Two sentences carry most of the design:

- **inputs = grants = your staged subtree** — what a generator may
  read, what a test may read, what the sandbox permits. corollary:
  *put it where its inputs are.*
- **a build runs only bytes you pinned, and only your code without a
  socket.** pins are data, `fetch` is the only networked verb, `exec`
  resolves only to pinned artifacts — so the external surface is
  enumerable from committed files.

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
| build inputs | enumerable from committed files — pins, `exec` targets, and the version stamp alike |
| generated outputs | never committed; everything generated lives in `o/` |
| generator units | directory-scoped; one per generated asset. a binary's `embed.gen.tl` fills `o/<unit>/{embed/,base}` |
| generator inputs | its containing subtree = its grants. reads outside are **denied**, not stale |
| grants | **derived** from each verb's signature; no declaration channel |
| enforcement | Landlock where available **plus** portable in-process gating |
| project root | cwd, with a loud guard if an ancestor also looks like a project |
| module root | the project root |
| public vs private | `_`-prefixed directory = importable only from within its container |
| this repo's layout | `cosmic/` is the public API; `_cli/`, `_build/`, `_make/`, `_types/`, `_perf/`, `_docs/` at root; `cmd/`; `3p/` — **landed, 3h**; `cosmic --make build` produces `o/bin/cosmic` |
| artifact layout | `/zip/<import path>.lua`, `embed/**` at the root |
| artifact contents rule | **shipping is opt-in**: modules plus `embed/**`, nothing implicit |
| `testdata/` | fixtures; not a module and not payload, so it never ships |
| paths | filenames with spaces or shell metacharacters are a validator error |
| network | only under `--make fetch`. **no project code ever runs with a socket** |
| pins | `*.pin.tl` — Teal, statically extracted from a literal, never executed |
| `exec` | resolves only to pinned/staged bytes under `o/`. never `PATH` |
| version stamp | read from the cosmos pin plus a committed `.version` (`COSMIC_VERSION` overrides); no host tool |
| recipe lines | whitespace-split argv; `argv[0]` ∈ closed verb set ∪ `exec` |
| `-c` vs `--build` | `-c` wins; `--build` retired across two release cycles |
| make's bytes | embedded in the cosmic release. amends D13 |
| provisioning | `bin/cosmic` fetches one pin here; **downstream projects commit their cosmic** |
| artifact base | `o/<unit>/base` if the unit names one, else the running cosmic, stripped to a positive floor |
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
| `<unit>/embed.gen.tl` | a **binary's payload generator** (reserved basename, its own kind) | the binary's scope readable, `o/<unit>` writable |
| `embed/**` | payload, embedded at its path inside `embed/` | — |
| `.cosmicignore` | exclusions | — |
| everything else | an asset: part of the project, **not** of its artifacts | — |

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
  `main.user` — but `cosmic` and `tl` are *providable*. A project that
  defines the namespace's root module (`cosmic/init.tl`, `tl.lua`)
  claims the whole namespace, and the artifact drops the base's copy so
  one definition ships. Providing a *piece* stays refused: that is the
  case the rule exists for, where `require("cosmic.fs")` finds the
  project and `require("cosmic.json")` finds the base. `cosmo` is a
  native binding and `main.user` is the wrapper's own slot, so neither
  can be claimed at all. This is what lets cosmic build itself.
- **`cmd/foo` cannot import `cmd/bar`.**
- **filenames with spaces or shell metacharacters are refused**, so
  recipe splitting is total and quoting never exists. Accepted cost: a
  legitimate `my notes.tl` is rejected, by name.
- **`.lua` sources are first-class**; `foo.tl` beside `foo.lua` is an
  error, not a precedence rule.

### Units

**A `cmd/<name>/` directory is a generator.** Noticed while building
2c, and it is not a coincidence: every output under `o/` is produced by
a *unit*, and a unit is three things — a **directory** that declares
it, a **scope** of inputs that is also its grant set, and an **output
path** derived from its position. Nothing else varies.

| unit | declared by | scope = grants | output |
|---|---|---|---|
| module | `X.tl` | the file + the include path | `o/X.lua` |
| test | `X_test.tl` | staged subtree at its directory + staged modules | `o/X.tl.test.{got,out,err}` |
| generator | `*.gen.tl` in `D` | `D`'s subtree | `o/D/**` |
| payload generator | `embed.gen.tl` in unit `U` | `U`'s binary scope | `o/U/{embed/,base}` |
| binary | `main.tl`, `cmd/<n>/main.tl` | root packages + its own `cmd/<n>/**` | `o/bin/<n>` |
| pin | `*.pin.tl` in `D` | the pin literal, plus a socket under `fetch` | `o/D/<name from the url>` ⚠ |

Read down the scope column and the design's two load-bearing sentences
are one: *inputs = grants = your staged subtree*, and *put it where its
inputs are*. `cmd/foo` cannot import `cmd/bar` is not a special
artifact rule — it is that unit's scope, stated as a validator error
rather than a denied read because it can be caught statically.

What this buys: `exec`'s fence gets a referent; staging becomes one
question, `scope_of(unit)`, that the artifact, the test stage and a
generator's read grant all ask; and a new unit kind costs a table row.
What it does *not* buy: the rows differ in the one place that matters —
how the scope is computed — so a `Unit` record is a bag of five
unrelated functions until at least three exist.

**How to investigate it.** Not by staring at the table — by writing the
next scope *without* consulting the last one. Two rows falsified a
prediction; one is now closed. A binary's payload generator reads the
*binary's* scope rather than its own subtree — that is a distinct row
above and a distinct **kind** (`payload-gen`) out of `classify`, with a
validator rule for a stray `embed.gen.tl` where no binary lives; it used
to be one kind split by prose plus a basename match inside the runner,
which left `cmd/foo/data.gen.tl` a file neither mechanism would run. A
pin's output path is still named by the url inside it (hence the ⚠),
and retires with the second pin reader — see the pin grammar below.
The `Unit` record is not earned; the smaller `unit_dir(path)` the fence
wants is.
Method and findings: [make-plan.md](make-plan.md), 2d.

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

### A binary's own generator

`<unit>/embed.gen.tl` is the one generator `build` runs itself, and it
is not a generation unit: its scope is the *binary's* scope, because
what it produces is the binary's payload. It is handed its unit's
output directory and owns two names inside it:

```
o/<unit>/embed/**   what the artifact carries — staged at the zip root
o/<unit>/base       what it carries it on — the runtime to embed onto
```

`embed/` is the generated half of the committed `embed/` convention;
both land at the same place and nothing downstream can tell which was
which. `base` exists because the alternative is embedding onto the
cosmic running the build, and stripping a base drops its zip entries
without reclaiming their bytes — so cosmic-built-by-cosmic grew by its
own payload every generation. A project that pins a runtime names it
here; one that pins nothing keeps the running cosmic. Running the
generator from `build` is the usual staleness argument: its output is
in the binary's build closure.

`.args` — the APE's default argv — is **derived**: the entry is always
`/zip/main.lua` here, so what argv names is a fact about the layout,
not a choice. A payload `.args` overrides it.

### External assets and execution

Fetching is **not** a generator. A `*.pin.tl` is Teal data — a single
`return { … }` literal, type-checked, **statically extracted from the
AST and never executed**. `--make fetch` downloads, verifies, and lands
the bytes under `o/`; `build` never opens a socket. A pin that declares
a `format` is unpacked beside its archive, *after* the digest matched:
an archive is a program for a decompressor, and running one on
unverified bytes is what pinning exists to prevent.

`exec` resolves only to pinned or staged bytes under `o/` — never a
`PATH` lookup. A project may run a tool it pinned; it cannot run
whatever happens to be installed.

Two frays in the pin grammar are **scheduled, not settled** — the
url-derived landing name (the ⚠ above) and the dual `sha`/`platforms`
spelling that exists so one file can satisfy both pin readers. Both
retire with the second reader; see [make-plan.md](make-plan.md), 3i.

Together: *building an untrusted repo cannot phone home, and cannot run
a host binary.* Both halves of the external surface are greppable.

Corollary, and the reason the version stamp is generated rather than
shelled out for: `git describe` is not available to a build. Both
halves are **read** — the cosmos half from its pin, the project half
from a committed `.version` (the same literal grammar, so it is data
the build never executes), falling back to `COSMIC_VERSION` and then to
`unknown`. No host tool, no `.git` read.

The committed file is what keeps the enumerable-inputs property whole
(D16): `COSMIC_VERSION` alone made two builds of one commit differ by
ambient environment, and made the gen2 = gen3 fixpoint depend on a
precondition no committed file recorded.

## Artifact model

### Layout

Assembled from the **effective tree** — sources overlaid with `o/`
outputs — through one rule:

```
package module, import path P  →  /zip/P.lua
payload under `embed/`         →  /zip/<path inside embed/>
entry                          →  /zip/main.user.lua behind the wrapper
```

The zip root *is* the module root, so "path relative to root = import
path" holds inside the artifact too. `pack_copies` disappears; the
layout is derived, not enumerated.

**Shipping is opt-in** (D15): an artifact carries its modules plus
`embed/**` and nothing else. Every other kind is something you *did*,
and "everything else, embedded at its relative path" was the one row
that inverted it. With shipping opt-in there is nothing to un-ship, so
`.cosmicignore` stays a purely model-scoped knob and `testdata/`'s
exclusion stops being an exception carved out of a default. Cost: a
`schema.sql` an artifact needs becomes `embed/schema.sql`. Cosmic's own payload moved with it
in 3d (`/zip/.lua/cosmic/*` → `/zip/cosmic/*`): cosmopolitan's default
`package.path` is `/zip/.lua/`-rooted, so the entry inserts the zip
root ahead of it — behind anything `LUA_PATH` set, or the binary's own
copy shadows an in-tree build. Payload that is *not* modules (the type
tree, `.tl` sources, the docs index) stays dot-prefixed, outside the
module root.

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

A unit that names its own `base` sidesteps this: there is nothing to
strip off a bare runtime. That is the preferred shape for a project
that pins one, and the only shape in which repeated self-builds
converge — `remove` drops zip entries without reclaiming their bytes,
so stripping a cosmic to rebuild a cosmic leaves the old payload behind
as dead space. Sizes and the per-generation growth measured before
`base` existed are in [make-plan.md](make-plan.md).

Risk: a `cosmo.*` binding lazily requiring a stripped `.lua/cosmo/**`
helper. Gate: a **stripped-artifact test lane** running the stdlib's own
tests inside a stripped artifact.

### Reproducibility

Entries carry a fixed mtime (`SOURCE_DATE_EPOCH`, else the DOS floor
315532800) rather than the staging file's. Plumbed through `embed.run`
and DEFAULTED there, so `--embed` is reproducible too and not only the
`--make` path that passes one explicitly. Gate: build
the same fixture twice into different paths, compare sha256.

## Engine

The engine chapter — constant rules and generated facts, cosmic as
`SHELL`, the closed verb vocabulary and its grants, staleness and
parallelism — is [make-engine.md](make-engine.md). It moved out when
this file hit the 500-line cap; the split is by chapter, the way
`_perf/optimize/` is split, so no chapter has to fight the cap.

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
build [binaries…] compile → generate → stage → embed → o/bin/<name> [now]
test  [paths…]  build the stage, run *_test.tl fenced against it     [now]
check [paths…]  strict type-check only                               [now]
fmt   [paths…]  --check-format (--fix to rewrite)                    [now]
fetch [paths…]  resolve *.pin.tl — the only verb with network        [now]
clean           remove o/                                            [now]
run   [binary]  build, then exec the artifact with remaining argv    [planned]
regen [paths…]  run generation units                                 [planned]
example [paths…] run Example_* against the staged tree               [planned]
lint  [paths…]  style gate: file length, column width, cast ratchet  [planned]
```

**Selection names targets of the verb's own kind, and never changes
what a target means** — `test` states it as "selection changes which
tests run, never what gets staged". `build`'s targets are BINARIES, so
`build cmd/foo` (or `build foo`) builds foo: the full pipeline, staging
what a full build would, and never a narrowed compile. A source path is
refused, pointing at `check`, whose targets *are* sources.

**Policy verbs** — orchestration over the graph, never graph rules.
All planned; `bin/make` owns these lanes today:

```
ci              format → check → test → example → lint → coverage
coverage        tests with line coverage + ratchet
enforce         sandbox-enforced lane
reproducible    double-build + compare
offline         no-network lane, asserted against the pins
```

`example` and `lint` are verbs in their own right (planned, above), so
`ci` is a list of verb names rather than a lane reimplementing two of
its six stages. `example` is `test`'s sibling — same staging, same
fence, `Example_*` instead of the test contract — which is what the
model already says everywhere else. `lint` stays out of `check`: its
file set is the whole tree, not the compiled closure.

`ci` is a fixed order with **each stage gated by whether the project has
material for it** — no tests, no test stage; no committed coverage
baseline, no ratchet. Zero configuration, and a fresh project doesn't
fail on a stage that had nothing to do. (A baseline is *input* data, so
it stays committed; only generated things are banned from the tree.)

Every verb ends in a machine-readable verdict line and an exit code.

