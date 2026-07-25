# Design — `cosmic --make`

status: proposal, for review. three review rounds are folded in; the
decision tables are the record. delivery is in
[make-plan.md](make-plan.md).

`--make` is **cosmic's build system**, not a wrapper around `--embed`.
This repo is meant to build with it.

## What this replaced

`--make [dir] [target]` scanned for `*.tl`, classified by suffix, emitted
a Makefile and ran make on it. Three things were wrong with that, and
they are what this design addresses: it **needed a host make** (the
generated file is useless without one, contradicting promise 3 for
exactly the user cosmic is for); it **produced build files, not builds**
(no rule made an executable); and its **project model was a flat scan** —
no packages, no entry point, no artifact, no notion of what ships. It was
dropped whole in 2a.

Three fixes that landed this week are also evidence for the design's
central bet, that a hand-maintained description of a project drifts from
the project:

- **#800** — `lib/build`, `lib/docs`, and `lib/types` were not
  type-checked or format-checked at all, because no `cook.mk` declared
  their sources. Three directories, silently outside the gates.
- **#802** — the teal and format gates "never ran the check they
  report": an argv-ambiguity bug meant they passed everything.
- **#799** — lint only saw *tracked* files, so a new file got no lint
  locally and first failed in CI.

Under conventions, the first cannot happen (a package is a directory
with sources in it, discovered, never declared), and the closed recipe
vocabulary removes the argv ambiguity behind the second. The third is a
policy the `lint` verb inherits: **tracked plus untracked-not-ignored**.

Two primitives this design needs also already exist: `child.spawn`'s
`"inherit"` stdio mode (#798), which is how a recipe step streams while
it runs, and `--test`'s argv slicing (#804), which the `test` verb keeps.

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
| grants | **derived** from each verb's signature; no declaration channel |
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
| binary | `main.tl`, `cmd/<n>/main.tl` | root packages + its own `cmd/<n>/**` | `o/bin/<n>` |
| pin | `*.pin.tl` in `D` | the pin literal, plus a socket under `fetch` | `D/<name from the url>` ⚠ |

Read down the scope column and the design's two load-bearing sentences
are the same sentence: *inputs = grants = your staged subtree*, and
*put it where its inputs are*. `cmd/foo` cannot import `cmd/bar` is not
a special artifact rule — it is that unit's scope, stated as a
validator error instead of as a denied read, because it can be caught
statically.

What this buys: `exec`'s fence gets a referent (it is the one verb
whose reads argv cannot derive, and the design already promises it is
"fenced to the unit's subtree"); staging becomes one question,
`scope_of(unit)`, that the artifact, the test stage and a generator's
read grant all ask; and a new unit kind costs a table row.

What it does *not* buy, and why this is a recorded observation rather
than a refactor: the rows differ in the one place that matters — how
the scope is computed — so a `Unit` record is a bag holding five
unrelated functions until at least three exist.

**How to investigate it, and what came back.** Not by staring at the
table — by writing the next scope *without* consulting the last one and
seeing what it wants. Three predictions were recorded before 2d, and
2d's pin falsified one of them: an output path is **not** always
derivable from position (a pin's is named by the url inside it, hence
the ⚠ above). The `Unit` record is therefore not earned; what the
evidence supports is the smaller `unit_dir(path)` the fence wants,
while "scope as a file list" turns out to be a question only the
artifact and the test stage ask. The predictions, the method and the
findings are in [make-plan.md](make-plan.md) under 2d.

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
- **sandboxing stops depending on fork-specific syntax, and on any
  declaration at all.** grants are *derived from the verb's signature*:
  `copy <src> <dst>` reads src and writes dst, `compile <bootstrap>
  <src> <out>` execs the first, reads the second, writes the third.
  cosmic self-restricts from that before dispatching, so
  `.PLEDGE`/`.UNVEIL` attributes become optional rather than
  load-bearing — and a rule cannot over-declare its way out of the
  fence, because a rule declares nothing.

  An earlier version of this design carried grants in target-specific
  make variables (`COSMIC_UNVEIL = $^`). Closing the vocabulary made
  that channel redundant: the argument positions *are* the declaration.
  Two mechanical details the kernel forces, recorded because getting
  them wrong disables the fence rather than tightening it — a write
  grants the parent **directory** (creating and unlinking are rights on
  the directory, and the output does not exist yet), and a read naming
  a path that does not exist is **dropped**, since landlock opens every
  rule and one missing input would fail the whole restrict.

  `exec` is the one verb whose reads are not derivable — a pinned
  compiler reads headers nobody listed — so it is fenced to the unit's
  subtree instead of its argv, per the same rule generators and tests
  use.

  **A derived fence still needs a floor.** Shipping the derivation with
  nothing else turned three CI lanes red at once: argv says nothing
  about the APE loader beside a binary (a fat APE that cannot reach it
  fails `ENOEXEC`, which reads like a corrupt file rather than a denied
  path), nor about `/dev/urandom`, nor about the paths a *child's* own
  argv names — `tee <out> cosmic --report <got…>` hands those to a
  process that inherits the fence. The make rules already spell this
  floor as `unveil_base`/`unveil_dev`; the derived fence needs its own.
  It is therefore **opt-in (`COSMIC_FENCE=1`) until the canary proves
  it on a Landlock host** — no machine available while writing it could
  enforce anything, so every local run was a silent no-op.

**The trailing `;` is load-bearing.** Setting `SHELL` is not enough:
make does not use `SHELL` for a line it judges shell-free — job.c
builds argv and execs directly whenever the line contains none of
`` #;"*?[]&|<>(){}$`^ `` and does not start with a shell builtin. Lines
in this vocabulary are shell-free *by construction*, so the naive
`SHELL := cosmic` intercepts nothing at all: measured on the fork, a
recipe of `rm -rf a.txt` under `SHELL := cosmic` deleted the file, and
`copy a.txt out.txt` failed with `copy: No such file or directory`
because make tried to exec `copy` as a program. `.ONESHELL` does not
change it.

So generated recipe lines end in `;`, which forces the `SHELL` path,
and `-c` strips exactly one trailing sentinel before dispatch. A `;`
anywhere else is still refused, so `copy a b ; touch evil` does not
become two commands. `;` is the cheapest sentinel that behaves
identically under a real shell — a leading `:` also forces the path,
but `sh` would discard the line's arguments entirely.

The alternative is a fork change (a special target that forces the slow
path), which is the D14 mechanism and remains open — but the sentinel
needs no release, so the upstream knob is an ergonomic cleanup rather
than a dependency.

**`exec` opens onto pinned bytes only.** It resolves against the build
root (`$COSMIC_EXEC_ROOT`, else `o/`) and refuses anything outside it,
so a bare `exec cc` resolves to `<cwd>/cc`, is not under the root, and
is refused rather than silently picking up the host's compiler. Pins
declare bytes, `fetch` obtains them, `exec` runs them; nothing else
runs at all.

Known limitation, recorded rather than papered over: a program's
*arguments* travel through the same whitespace split, so they cannot
carry shell characters either. A pinned compiler invoked with
`-DFOO(x)=y` is refused. Nothing in this repo's rules needs it, and the
out-of-band channel that would fix it (paths and args in target-specific
variables rather than in the line) was considered and rejected for
costing the legibility of `o/cosmic.mk`. If a real project hits it, that
tradeoff is the thing to revisit.

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
jobserver and an explicit `--jobs`). Parallel-by-default is defensible
only because isolation is structural.

Spawn cost, measured (phase 1's deliverable, 200 runs of a no-op verb):
**10.4 ms** per line for the fat APE, **6.4 ms** for the assimilated ELF
the sandboxed rules already exec, against **1.5 ms** for `/bin/sh -c
true`. The comparison that matters is not against a shell, though: this
repo's recipes *already* spawn cosmic per line (`$(bootstrap_cosmic)
--build …`), so routing through `SHELL` costs the same one spawn — the
shell it replaces was never free either. At 6 ms, a 1000-node graph
carries ~6 s of startup serially, under a second at `-j8`. That is the
budget; it argues for chunky verbs and, eventually, the action cache.

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

