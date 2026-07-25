# Design — `cosmic --make`

status: proposal, for review. two review passes are folded in; the
decision tables below are the record.

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
   a cosmic verb or the explicit `exec`. cosmic reads the rule's grants
   from target-specific variables and self-restricts before working.
4. **the pinned make, embedded** — extracted to a cache dir on first
   use. one binary, offline, no host toolchain.

```
$ cosmic --make build          # strict check, compile, stage, embed → ./myapp
$ cosmic --make test           # tests, fenced, against the staged tree
$ cosmic --make fetch          # the only verb that touches the network
$ cosmic --make coverage       # policy verb, not a graph rule
```

One rule runs through the whole design: **inputs = grants = your staged
subtree.** It defines what a generator may read, what a test may read,
and what the sandbox permits — the same sentence in all three places.
"Put it where its inputs are" is the corollary, and position is
therefore load-bearing for generators and tests alike.

## Decisions

| question | decision |
|---|---|
| primary pain | multi-file projects; tests over the code that ships. then rebuild cost/determinism, then discoverability |
| `build` semantics | strict type-check + compile + stage + embed. `test` is a separate verb |
| what tests import | the **staged tree** — the exact compiled `.lua` the artifact embeds |
| binaries per project | root `main.tl`, plus `cmd/<name>/main.tl` per artifact |
| artifact contents | root packages + its own `cmd/<name>/**`. `cmd/foo` cannot import `cmd/bar` |
| CLI | `cosmic --make <verb> [path]`, verb first |
| make's job | sandboxed steps first, then staleness, then parallelism |
| rules source | conventions only. no `rules.tl`. cosmic reshapes itself to fit |
| policy lanes | cosmic **verbs**, not graph rules |
| built-in opinions | none. no automatic version stamp, no automatic doc index |
| generated outputs | never committed; everything generated lives in `o/` |
| generator units | directory-scoped; one directory per generated asset |
| generator inputs | its containing subtree = its grants. reads outside are **denied**, not stale |
| enforcement | Landlock where available **plus** portable in-process gating |
| project root | cwd, with a loud guard if an ancestor also looks like a project |
| module root | the project root. cosmic's own tree flattens (`lib/cosmic/` → `cosmic/`) |
| artifact layout | unified *down*: `/zip/<import path>.lua`, assets at `/zip/<rel>` |
| paths | filenames with spaces or shell metacharacters are a validator error |
| network | only under `--make fetch`. **no project code ever runs with a socket** |
| pins | `*.pin.tl` — Teal, statically extracted from a literal, never executed |
| recipe lines | whitespace-split argv; `argv[0]` ∈ closed verb set ∪ `exec` |
| `-c` vs `--build` | `-c` wins; `--build` retired across two release cycles |
| make's bytes | embedded in the cosmic release. amends D13 |
| artifact base | stripped to a positive floor. no opt-out |
| the floor | compiled stdlib + certs + zoneinfo + `.args`; verified by test |
| generated makefile | written to `o/`, documented, readable |
| generality | constant rules + generated facts (variables only) |
| staleness | mtime schedules, content decides (write-if-changed everywhere) |
| parallelism | everything parallel; spawn cost is a budget, not an excuse |
| test isolation | writes `TEST_TMPDIR` only; reads = staged subtree + staged modules |

## Project model

| marker | declares | grants |
|---|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format | sources readable, `o/<dir>` writable |
| `*_test.tl` | a test target | staged subtree readable, `TEST_TMPDIR` writable |
| `*_example.tl` | an example target | same |
| `*.d.tl` | type-only; include path, never embedded | — |
| `main.tl` at root | the project's binary | staged tree readable, output dir writable |
| `cmd/<name>/main.tl` | one binary per subdirectory | same |
| `<dir>/*.pin.tl` | a pinned external asset | network **only** under `fetch`; `o/<dir>` writable |
| `<dir>/*.gen.tl` | a generation unit | its subtree readable, `o/<dir>` writable |
| `.cosmicignore` | exclusions | — |
| everything else | an asset, embedded at its relative path | — |

- **import path = path relative to root, `/`→`.`, extension dropped.**
  `pkg/db.tl` → `require("pkg.db")`; `pkg/init.tl` → `require("pkg")`.
- **the project root is the module root.** cosmic's own tree therefore
  flattens: `lib/cosmic/` → `cosmic/`, `lib/types/` → `types/`, and so
  on. rejected alternative: a conventional `lib/`/`src/` source root —
  one extra clause, and rearranging is cheap.
- **root discovery: cwd.** an explicit path argument overrides. if an
  ancestor directory also looks like a project (has `.tl` files or a
  `cmd/`), `--make` **refuses**, naming the likely intended root and the
  exact command. every invocation prints `make: root=<path>`, so the
  answer is never inferred.
- **`.lua` sources are first-class**; `foo.tl` beside `foo.lua` is an
  error, not a precedence rule.
- **reserved import paths refused**: `cosmic`, `cosmo`, `tl`,
  `main.user`.
- **`cmd/foo` cannot import `cmd/bar`** — stated by the validator.
- **filenames with spaces or shell metacharacters are refused.** recipe
  lines are whitespace-split argv, so this keeps the split total and
  quoting from ever existing. the cost is real and accepted: a
  legitimate `my notes.tl` is rejected with an error naming the file.

### Generators

A generation unit is a directory holding a `*.gen.tl`; one directory per
generated asset. Its **inputs are its containing subtree, and its grants
are exactly that set** — so a generator that reads outside its scope
gets a denied read, not a silently stale output. Outputs go to
`o/<dir>/`; nothing generated is ever committed.

Enforcement is doubled deliberately, because `unveil()` no-ops off
Landlock: kernel enforcement where available, plus **in-process gating**
of `cosmic.fs`/`io` for the generator's duration, so the rule holds on
macOS and Windows too and the developer meets it on the machine where
they wrote it. Same error message from both paths.

Because generated output is never committed, the drift class disappears:
there is no committed copy to drift from. Accepted cost: **you can no
longer read `cosmo.*` types from a fresh clone without building**, and
editors need `o/` on the include path. This is the sharpest edge in the
design and it pulls against the bare-sandbox story.

### External assets

Fetching is **not** a generator. A `*.pin.tl` is Teal data — a single
`return { … }` literal, type-checked like everything else, **statically
extracted from the AST and never executed**. `--make fetch` downloads
and verifies the sha; `build` never opens a socket.

Two properties this buys, both stated as one sentence each:

- **a cosmic build never runs your code with a socket.** building an
  untrusted repo cannot phone home, because no project code is ever
  granted network — not even a pin.
- **a project's entire external surface is greppable.** pins are data,
  so auditing, mechanical bumping, and the `offline` verb all work
  without evaluating anything.

Accepted cost: sources cosmic doesn't implement (git, a private index)
are unsupported until cosmic implements them.

## Artifact model

### Layout

Assembled from the **effective tree** — sources overlaid with `o/`
outputs — through one rule, unified *downward*:

```
package module, import path P  →  /zip/P.lua
asset at relative path R       →  /zip/R
entry                          →  /zip/main.user.lua behind the wrapper
```

The zip root *is* the module root, so "path relative to root = import
path" is literally true inside the artifact too. `pack_copies`
disappears; the layout stops being enumerated and becomes derived.

Consequence: cosmic's own payload moves (`/zip/.lua/cosmic/*` →
`/zip/cosmic/*`, `.lua/tl.lua` → `tl.lua`, `.lua/types/` → `types/`),
touching the searcher's include dirs and anything with a hardcoded
`/zip/.lua/`. Contained, and it lands in phase 3 when the pack rule is
rewritten anyway.

### Stripping

The base is **always stripped to a positive keep set**; anything above
the floor is the project's own files. There is no `--keep`.

**Floor:** compiled cosmic stdlib, TLS roots, zoneinfo, `.args`.
**Stripped:** the embedded make, `tl.lua`, types, teal-types, cosmic's
`.tl` sources, docs index, skills, `sys/`, `definitions.lua`,
`.lua/cosmo/**`.

This is what lets cosmic build itself with no exception: its artifact
carries `tl.lua`, types, docs, and make because **its own tree provides
them** — from its pins and generators — not because the base kept them.
Any user wanting Teal at runtime vendors it the same way; it is no
longer free.

Measured, against the 6.48 MB `cosmic-lua` release whose entire zip
payload is 0.66 MB compressed (the rest is two-arch native code):

| item | compressed |
|---|---|
| embedded make (new) | ~760 KB |
| `.tl/` cosmic sources | 104 KB |
| `definitions.lua` | 94 KB |
| docs index | 89 KB |
| `tl.lua` | 76 KB |
| types + teal-types | ~110 KB |
| **floor** | ~160 KB |

Stripping recovers ~1.2 MB — it pays for the embedded make and lands a
hello-world slightly under today's binary. **It is not a size win beyond
that**; the mass is native code, and the only lever with real weight is
single-arch output, which costs the fat-binary promise.

Risk: a `cosmo.*` binding that lazily requires a stripped
`.lua/cosmo/**` helper. The gate is a **stripped-artifact test lane**
running the stdlib's own tests inside a stripped artifact.

### Reproducibility

Entries carry a fixed mtime (`SOURCE_DATE_EPOCH`, else the DOS floor
315532800) rather than the staging file's; `AddOptions.mtime` exists in
the binding and is simply not plumbed through `embed.run` today. Gate:
build the same fixture twice into different paths, compare sha256.

## Engine

### Constant rules, generated facts

`o/cosmic.mk` ships in the binary, byte-identical everywhere; discovery
inside it uses `$(wildcard)` and `rwildcard` foreach-recursion —
builtins only, no `$(shell)`. `o/project.mk` is generated and contains
only variable assignments.

Codegen shrinks to "emit a list of variables"; discovery and validation
stay in Teal, where errors can be good. This repo's makefile ratchets
collapse from "scan generated recipe text" to "one file that does not
change." Cost: a stale `o/project.mk` if someone runs
`make -f o/cosmic.mk` directly.

### Cosmic as `SHELL`

`SHELL := cosmic`; cosmic grows `-c '<line>'`, so make's default
`.SHELLFLAGS` works unchanged. A line is whitespace-split argv — no
quoting, no expansion, no pipes, no redirects — whose `argv[0]` must be
a cosmic verb or the explicit, greppable `exec`.

- **the build's capability surface is enumerable.** the recipe
  vocabulary is closed and documented; the metacharacter-scanning
  ratchet becomes unnecessary.
- **sandboxing stops depending on fork-specific syntax.** grants ride in
  target- and pattern-specific variables (`COSMIC_UNVEIL = $^`, plain
  GNU make) and cosmic self-restricts. `.PLEDGE`/`.UNVEIL` attributes
  become optional rather than load-bearing.

`--build` and `-c` are the same dispatcher; `-c` wins. Retirement is
release-bounded and the ordering is a constraint, not a preference:
`-c` must ship in a release **before** this repo can set
`SHELL := cosmic`, because recipes run the pinned older bootstrap.
Sequence: add `-c` → release → bump the pin → switch `SHELL` and migrate
recipes → remove `--build` the following release.

### Staleness and parallelism

Mtime schedules; content decides. Every verb writes its output only when
the bytes change — the existing `run_into` contract, generalized to
every step by cosmic owning the shell. A no-op step doesn't touch its
output, so non-changes stop propagating.

**Everything is parallel** (`-j$(nproc)`, honoring an inherited
jobserver and an explicit `--jobs`). Cosmic is spawned once per recipe
line; that cost is treated as a **budget to hold, not a reason to
serialize** — phase 1 reports the number and optimizes the startup path
if it isn't small. Parallel-by-default is only defensible because
isolation is structural (below), not advisory.

An action cache keyed on `(argv + input hashes)` is the natural next
step, deliberately deferred until profiling justifies it.

## Tests

Same rule as generators: **inputs = grants = your staged subtree.**

- **writes:** `TEST_TMPDIR` only. A write anywhere else is a denial, on
  the author's machine, at the moment it happens.
- **reads:** the staged subtree rooted at the test's own directory, plus
  the staged module tree it imports. Everything else — other packages'
  sources, `$HOME`, the live tree — is denied.
- **one shared stage** per run, read-only, so reads are of an immutable
  snapshot. That removes the read-a-file-another-test-is-writing class
  outright and costs one stage, not one per test.
- fixtures need no `testdata/` convention: anything in the test's own
  subtree is readable.
- ambient environment is redirected into the test's directory
  (`TMPDIR`, `HOME`, `XDG_*`, cwd), with `TEST_SRCDIR` pointing at the
  staged subtree.
- `testrun`'s `.got`/`.out`/`.err` contract and `status_of` (0 pass /
  2 skip / other fail) are unchanged.

**Ports are a known, documented gap** — fencing can't see them.
`TEST_PORT_BASE` or a `net` helper, later.

Consequence for this repo, and the reason position matters: ratchet
tests that read the live tree (`makefile_ratchet_test.tl`, the cast and
coverage ratchets) must **move to where their inputs are** — the project
root, whose subtree is the whole staged tree. Rearranging to fit the
convention is preferred over adding a clause for them.

## Verbs

**Graph verbs** — lower to make and run the graph:

```
build [path]    strict check → compile → stage → embed
test  [path]    build the stage, run *_test.tl fenced against it
check [path]    strict type-check only
fmt   [path]    --check-format (--fix to rewrite)
run   [path]    build, then exec the artifact with remaining argv
regen [path]    run generation units
fetch [path]    resolve *.pin.tl — the only verb with network
clean           remove o/
```

**Policy verbs** — orchestration over the graph, never graph rules:

```
ci              format + check + test + example + lint + coverage
coverage        tests with line coverage + ratchet
enforce         sandbox-enforced lane
reproducible    double-build + compare
offline         no-network lane, asserted against the pins
```

Every verb ends in a machine-readable verdict line and an exit code.

## Trust root: amending D13, completing D14

**D13** rejects "shipping make inside the cosmic release binary… no
reduction in what must be trusted." Sound for *this repo's* build, where
both pins are in hand. It does not survive the user case: someone
holding one cosmic binary in a bare sandbox cannot build anything unless
make is inside it, and for them embedding collapses two pins to one.
Amended chain: **kernel → committed fetcher → one pin → everything.**
The cost D13 names — entangled release cycles — is real and bounded;
cosmic already pins `cosmos.zip` for its base binary.

**D14** is completed, not contradicted. It rejects a cosmic-native
*graph executor* and says the endgame "shrinks what make means — a job
execution system and dependency graph, nothing else." Exactly this: make
keeps the graph, jobserver, and scheduling; cosmic supplies the graph's
content, every recipe's semantics, and the sandbox. Its rejection of
"driving the build from a cosmic script that shells out to make" needs
revisiting — make remains the execution engine, not a subroutine.

## What this repo looks like afterward

| today | becomes |
|---|---|
| `cook.mk`, `mk/*.mk` | conventions |
| `lib/cosmic/`, `lib/types/`, … | `cosmic/`, `types/`, … (root = module root) |
| `cosmic_srcs`/`_tl`/`_tests` wildcards | package convention |
| `pack_copies` enumeration | the artifact layout rule |
| `3p/*/version.lua` | `*.pin.tl`, statically extracted |
| `gentype`/`gentl` rules | generation units, one directory each |
| doc index, version stamp | generation units, placed where their inputs are |
| `.PLEDGE`/`.UNVEIL`/`.ENV` | derived grants, enforced by cosmic-as-`SHELL` |
| `.SANDBOXED`, hostx, recipe-scan ratchets | mostly unnecessary; the vocabulary is closed |
| ratchet tests reading the tree | moved to the root, where their inputs are |
| coverage/enforce/reproducible/offline lanes | policy verbs |

`-include cosmic.mk` is the migration bridge only; it is not part of the
end state. What stays bespoke: the `git describe` version stamp (a
deliberate host dependency) and the first-fetch shell in `bin/make`.

## Gates for the change itself

- fixture projects — single-binary, `cmd/` multi-binary, `.lua`-only,
  mixed, assets, `.cosmicignore` — each built and *run*
- reproducibility: double-build into different paths, compare sha256
- stripped-artifact lane: the stdlib's own tests inside a stripped
  artifact (what makes the floor safe to shrink)
- sandbox canary under cosmic-as-`SHELL`, on a Landlock host **and**
  with the in-process gate, proving both produce the same denial
- fence tests: a generator reading outside its subtree, a test writing
  outside `TEST_TMPDIR` — both denied, with the message asserted
- verb-vocabulary ratchet: the closed recipe verb set cannot grow
  silently
- pin extraction: a `*.pin.tl` containing anything but a literal is
  rejected; a pin is never executed (asserted, not assumed)
- `o/`-only check: no generated file lands in the tree
- validator messages: reserved import path, `cmd/foo`→`cmd/bar`,
  `foo.tl`+`foo.lua`, missing entry, space in filename, ambiguous root —
  each asserted, since these are what a fresh agent hits first
- spawn-cost budget: `cosmic -c` under `-j`, reported in phase 1

## Phasing

1. **`-c` shell mode.** the closed verb vocabulary, grant
   self-restriction from target-specific variables, the portable
   in-process gate. this repo keeps `cook.mk` and switches `SHELL`
   *after* the release that ships `-c`. reports the spawn-cost number.
2. **User-facing `--make`.** constant rules + facts generator;
   `build`/`test`/`check`/`fmt`/`run`/`fetch`/`clean` over the
   conventions; fenced tests; artifact stripping; embedded make;
   reproducibility. **this phase answers the original ask** and ships
   independently of everything below.
3. **Dogfood.** flatten the tree to root=module-root; migrate families
   behind `-include cosmic.mk`: packages, tests/examples, pins,
   generators, the pack.
4. **Policy verbs.** `ci`, `coverage`, `enforce`, `reproducible`,
   `offline`; retire the ratchets the closed vocabulary makes moot.
5. **Deferred, on evidence.** action cache; port isolation; `--make
   explain`; single-arch artifacts.

## Open items

1. **confirm the flattening** (`lib/cosmic/` → `cosmic/`). it follows
   from root = module root, but it is a large mechanical change and I
   inferred it rather than asking.
2. **stripped-floor risk**: `.lua/cosmo/**` may back a lazily-required
   binding. the stripped-artifact lane is the gate; anything that comes
   back comes back with a test naming it.
3. **`--make` as a name** survives even though nothing makes a Makefile.
   `--build` is taken until phase 1 retires it — after which `--build`
   is free and `--make` could be renamed. worth deciding when it is.
4. **`ci` composition for user projects**: which verbs it runs, and
   whether a project can influence that without a spec file.
5. **test filtering** (`only=`-style) has no convention yet.
6. **ports** remain unfenced.
