# Project model

What a project *is*: markers the tree carries, and what each one grants.
Intent is declared by position or by filename — never by a list that can
go stale.

| marker | declares | grants |
|---|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format | sources readable, `o/<dir>` writable |
| `_<dir>/` | internal: importable only from within its container | — |
| `*_test.tl` | a test target | staged subtree readable, `TEST_TMPDIR` writable |
| `*_example.tl` | an example target | same |
| `*_benchmark.tl` | a benchmark target | same |
| `testdata/` | test fixtures; **never embedded** | readable (it is in the subtree) |
| `*.d.tl` | type-only; include path, never embedded | — |
| `cmd/<name>/main.tl` | one binary per subdirectory, named `<name>` | staged tree readable, `o/bin` writable |
| `main.tl` at root | **refused**: a binary is named by its `cmd/<name>/`, never by the checkout directory | — |
| `<dir>/*_pin.tl` | a pinned external asset | network **only** under `fetch` |
| `<dir>/*_gen.tl` | a generation unit | its subtree readable, `o/<its own path minus extension>` writable |
| `<unit>/embed_gen.tl` | a **binary's payload generator** (reserved basename, its own kind) | the binary's scope readable, `o/<unit>/embed_gen` writable |
| `embed/**` | payload, embedded at its path inside `embed/` — at the ROOT or under `cmd/<name>/` only; anywhere else is a validation error | — |
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

## Units

**A `cmd/<name>/` directory is a generator.** Noticed while building
2c, and it is not a coincidence: every output under `o/` is produced by
a *unit*, and a unit is three things — a **directory** that declares
it, a **scope** of inputs that is also its grant set, and an **output
path** derived from its position. Nothing else varies.

| unit | declared by | scope = grants | output |
|---|---|---|---|
| module | `X.tl` | the file + the include path | `o/X.lua` |
| test | `X_test.tl` | staged subtree at its directory + staged modules | `o/X.tl.test.{got,out,err}` |
| benchmark | `X_benchmark.tl` | same as a test | `o/X.tl.benchmark.{got,out,err}` |
| generator | `G_gen.tl` in `D` | `D`'s subtree | `o/D/G_gen/**` |
| payload generator | `embed_gen.tl` in unit `U` | `U`'s binary scope | `o/U/embed_gen/{embed/,base}` |
| binary | `cmd/<n>/main.tl` | root packages + its own `cmd/<n>/**` | `o/bin/<n>` |
| pin | `*_pin.tl` in `D` | the pin literal, plus a socket under `fetch` | `o/D/<name from the url>` ⚠ |

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
validator rule for a stray `embed_gen.tl` where no binary lives. A
pin's output path is still named by the url inside it (hence the ⚠),
and retires with the second pin reader — see the pin grammar below.
The `Unit` record is not earned; the smaller `unit_dir(path)` the fence
wants is.
Method and findings: [log/phase1-2.md](log/phase1-2.md), 2d.

## Generators

A generation unit is a directory holding a `*_gen.tl`; one directory per
generated asset. **Inputs are its containing subtree, and its grants are
exactly that set** — so a generator reading outside its scope gets a
denied read, not a silently stale output. Outputs go to `o/<path minus extension>/`.

Enforcement is doubled because `unveil()` no-ops off Landlock: kernel
enforcement where available, plus in-process gating of `cosmic.fs`/`io`
for the generator's duration, so the rule holds on macOS and Windows and
the developer meets it where they wrote it. Same message from both.

Nothing generated is ever committed, so the drift class disappears —
there is no committed copy to drift from. Accepted cost: **`cosmo.*`
types can no longer be read from a fresh clone without building**, and
editors need `o/` on the include path. This is the sharpest edge here.

## A binary's own generator

`<unit>/embed_gen.tl` is the one generator `build` runs itself, and it
is not a generation unit: its scope is the *binary's* scope, because
what it produces is the binary's payload. Like every generator it is
handed `o/<its own path minus extension>/`, and owns two names inside
it:

```
o/<unit>/embed_gen/embed/**   what the artifact carries — at the zip root
o/<unit>/embed_gen/base       what it carries it on — the runtime
```

The generator's name in the middle is what makes the directory
clearable. The engine empties it before each run, so a name the
generator stops writing stops shipping — the ordinary stale-output
rule, which generated payload was exempt from for as long as its output
sat in `o/<unit>/` beside the build's own per-file bookkeeping. That
sharing also cost a "does a generator live here" gate to tell payload
from build notes; a directory of its own retires it.

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

## External assets and execution

Fetching is **not** a generator. A `*_pin.tl` is Teal data — a single
`return { … }` literal, type-checked, **statically extracted from the
AST and never executed**. `--make fetch` downloads, verifies, and lands
the bytes under `o/`; `build` never opens a socket. A pin that declares
a `format` is unpacked beside its archive, *after* the digest matched:
an archive is a program for a decompressor, and running one on
unverified bytes is what pinning exists to prevent.

`exec` resolves only to pinned or staged bytes under `o/` — never a
`PATH` lookup. A project may run a tool it pinned; it cannot run
whatever happens to be installed.

Two frays in the pin grammar are **open, and now unblocked** — they
could not move while two build pipelines read the same committed pins,
and only one does now. The reader is already shared (`_make.pin`), so
each is a grammar change with one implementation to change.

- **The landing name comes from the url's tail** (the ⚠ above), which
  is why url-name validation has to exist at all, and why an on-disk
  name is coupled to a remote server's path layout. Retire it
  positionally: `3p/tl/tl_pin.tl` + `tar.gz` → `o/3p/tl/tl.tar.gz`,
  with an optional `output` field for archives whose inner layout makes
  the name matter. The url becomes purely *where the bytes come from*,
  and the guard's reason to exist disappears rather than being
  hardened. Close the ⚠ in the same change.
- **Integrity has two spellings**, flat `sha` and the `platforms`
  table, so one committed file could satisfy both readers. A pin that
  must be written twice can disagree with itself. Keep `platforms`
  (with `*` as the single-platform case), refuse the other with a
  pointer.

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
