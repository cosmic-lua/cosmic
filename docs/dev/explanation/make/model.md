# The project model

what a project is: the markers a tree carries and what each one
grants, for a contributor who changes the walk, the validator or a
unit's scope.

intent is declared by position or by filename, never by a list that
can go stale. the walk never sees dot-prefixed entries, the build
directory `o/`, or anything a `.cosmicignore` pattern matches. it
sees symlinks but does not follow them: only regular files become
project files.

| marker | declares | grants |
|---|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format | sources readable, `o/<dir>` writable |
| `_<dir>/` | internal: importable only from within its container | none |
| `*_test.tl` | a test target | the project readable, `TEST_TMPDIR` writable |
| `*_example.tl` | an example target | same |
| `*_benchmark.tl` | a benchmark target | same |
| `testdata/` | test fixtures, never embedded | readable, because it is in the subtree |
| `*.d.tl` | type-only: include path, never embedded | none |
| `cmd/<name>/main.tl` | one binary per subdirectory, named `<name>` | staged tree readable, `o/bin` writable |
| `main.tl` at the root | refused: a binary is named by its `cmd/<name>/`, never by the checkout directory | none |
| `<dir>/*_pin.tl` | a pinned external asset | network only under `fetch` |
| `<dir>/<stem>_patch.tl` | edits carried against `<stem>_pin.tl`'s unpacked products | none |
| `<dir>/*_gen.tl` | a generation unit | its subtree readable, `o/<its own path minus extension>` writable |
| `<unit>/embed_gen.tl` | a binary's payload generator, a reserved basename and its own kind | the binary's scope readable, `o/<unit>/embed_gen` writable |
| `embed/**` | payload, embedded at its path inside `embed/`. at the root or under `cmd/<name>/` only; anywhere else is a validation error | none |
| `.cosmicignore` | exclusions, read from the root only | none |
| `.version`, `.cosmic-coverage` | data the build reads: the version stamp and the coverage floor | none |
| everything else | an asset: part of the project, not of its artifacts | none |

the rules the table rests on:

- **import path = path relative to the root**, `/` becomes `.`, the
  extension drops. `pkg/db.tl` is `require("pkg.db")`; `pkg/init.tl` is
  `require("pkg")`.
- **the project root is the module root.**
- **root discovery is the current directory.** there is no search
  upward for a marker: a search can resolve to an ancestor project and
  write output into the wrong tree. the upward scan exists only to
  refuse. if an ancestor also looks like a project, `--make` names the
  likely root and the exact command. `COSMIC_MAKE_ROOT` names the root
  for a caller that cannot change directory, and suppresses the guard.
  every run prints `make: root=<path>` first.
- **`_` marks internal.** a directory whose name starts with `_` is
  importable only from within the directory that contains it. root
  `_cli/` is project-wide internal; `cosmic/_x/` is internal to
  `cosmic/`. the validator enforces it. three things derive from
  position instead of a manifest: the public API surface, what the
  docs generator documents, and the artifact floor.
- **reserved import paths are refused**: `cosmic`, `cosmo`, `tl` and
  `main.user`. `cosmic` and `tl` are providable: a project that defines
  the namespace's root module (`cosmic/init.tl`, `tl.lua`) claims the
  whole namespace, and the artifact drops the base's copy so one
  definition ships. providing a piece stays refused. that is the case
  the rule exists for, where `require("cosmic.fs")` finds the project
  and `require("cosmic.json")` finds the base. `cosmo` is a native
  binding and `main.user` is the wrapper's own slot, so neither can be
  claimed. the claim rule is what lets cosmic build itself.
- **`cmd/foo` cannot import `cmd/bar`.**
- **a filename with whitespace is refused.** recipe lines are
  whitespace-split argv with no quoting, so splitting is total. the
  accepted cost: a legitimate `my notes.tl` is rejected by name.
- **`.lua` sources are first-class.** `foo.tl` beside `foo.lua` is an
  error, not a precedence rule.

tests under `_make/` assert each validator message: a reserved import
path, a `cmd/foo` import of `cmd/bar`, `foo.tl` beside `foo.lua`, a
missing entry, whitespace in a filename, an ambiguous root, and an
internal import from outside its container.

## units

every output under `o/` is produced by a unit. a unit is three things:
a directory that declares it, a scope of inputs that is also its grant
set, and an output path derived from its position. nothing else
varies.

| unit | declared by | scope = grants | output |
|---|---|---|---|
| module | `X.tl` | the file plus the include path | `o/X.lua` |
| test | `X_test.tl` | the project, plus its staged closure | `o/X.tl.test.{got,out,err}` |
| benchmark | `X_benchmark.tl` | same as a test | `o/X.tl.benchmark.{got,out,err}` |
| generator | `G_gen.tl` in `D` | `D`'s subtree | `o/D/G_gen/**` |
| payload generator | `embed_gen.tl` in unit `U` | `U`'s binary scope | `o/U/embed_gen/{embed/,base}` |
| binary | `cmd/<n>/main.tl` | root packages plus its own `cmd/<n>/**` | `o/bin/<n>` |
| pin | `*_pin.tl` in `D` | the pin literal, plus a socket under `fetch` | `o/D/<the url's last segment>` |

read down the scope column and the design's two sentences are one:
inputs = grants = your staged subtree, and put a file where its inputs
are. "`cmd/foo` cannot import `cmd/bar`" is that unit's scope, stated
as a validator error rather than a denied read, because it can be
caught statically.

this buys three things. `exec`'s fence has a referent. staging is one
question, `scope_of(unit)`, that the artifact, the test stage and a
generator's read grant all ask. a new unit kind costs a table row. it
does not buy a shared `Unit` record: the rows differ in the one place
that matters, how the scope is computed, so `_make/artifact.tl`'s
`scope_of` is a plain function over the model.

a pin's output name is the last segment of its url, not its position.
the validator checks that segment before it reaches a path. that
coupling of an on-disk name to a remote server's layout is an open
item; see the pin grammar below.

## generators

a generation unit is a directory holding a `*_gen.tl`, one directory
per generated asset. its inputs are its containing subtree and its
grants are exactly that set, so a generator that reads outside its
scope gets a denied read, not a silently stale output. its output goes
to `o/<path minus extension>/`. the engine empties that directory
before each run, so a name the generator stops writing stops existing.
within one `--make` invocation a generator runs once, however many
verbs stage.

enforcement is Landlock where the host has it. `unveil()` is a no-op
without Landlock, so a host that cannot enforce runs unfenced. a
portable in-process gate that produces the same denial on macOS and
Windows is planned and not built.

nothing generated is committed, so there is no committed copy to drift
from. the accepted cost: the `cosmo.*` types cannot be read from a
fresh clone without building, and an editor needs `o/` on its include
path. this is the sharpest edge in the model.

a generator runs before the graph, so it has no built closure to
resolve its own imports through. the engine compiles the generator's
import closure strictly into `o/` first, then runs the generator
against those built files. that closure is small: `_types/types_gen.tl`
needs about twenty files of this repo's several hundred. the closure
compile does not deadlock on itself. strict-compiling the generator
that produces the `cosmo.*` declarations succeeds with
`o/_types/types_gen/` absent, because the include path falls back to
the running binary's bundled `/zip/.types`. that fallback is the one
place a build reads the running binary's bytes on purpose.
[resolution.md](resolution.md) has the rest of the rule.

## a binary's own generator

`<unit>/embed_gen.tl` is the one generator `build` runs itself, and it
is not a generation unit. its scope is the binary's scope, because
what it produces is the binary's payload. like every generator it owns
`o/<its own path minus extension>/`, and two names inside it:

```text
o/<unit>/embed_gen/embed/**   what the artifact carries, at the zip root
o/<unit>/embed_gen/base       what it carries it on: the runtime
```

`embed/` here is the generated half of the committed `embed/`
convention. both land at the same place, and nothing downstream can
tell which was which. `base` exists because the alternative is
embedding onto the cosmic running the build, and stripping a base
drops zip entries without reclaiming their bytes; a cosmic built on a
cosmic grows by its own payload every generation. a project that pins
a runtime names it here. a project that pins nothing keeps the running
cosmic. a unit that also writes `base-<variant>` beside `base` gets a
second artifact, `o/bin/<name>-<variant>`, with the same payload on
that runtime. that is how one build makes `cosmic` and `cosmic-debug`.

`.args`, the APE's default argv, is derived. the entry is always
`/zip/main.lua`, so what argv names is a fact about the layout, not a
choice. a payload `.args` overrides it.

## external assets and execution

fetching is not a generator. a `*_pin.tl` is Teal data: a single
`return { … }` literal, type-checked, statically extracted from the
AST and never executed. `cosmic.literal` is the reader, and it refuses
a pin that is not a literal. `--make fetch` downloads, verifies and
lands the bytes under `o/`, beside the pin. bytes that do not hash to
the pin are never written. `build` never opens a socket.

a pin's fields: `url`, with `{version}` and `{platform}` substituted;
`version`; a digest, either `sha256` at the top level or `sha` on the
matching `platforms` row, where `*` is the row for a pin that is the
same everywhere; an optional `format`, `zip` or `tar.gz`; and
`strip_components`, the leading path segments to drop when unpacking.
a pin that declares a `format` is unpacked beside its archive after
the digest matched. an archive is a program for a decompressor, and
running one on unverified bytes is what pinning exists to prevent.

a `<stem>_patch.tl` beside an archive pin carries edits against the
unpacked products: each names an exact `find` string that occurs once
in one file and the `replace` that takes its place. a pin bump that
moves an anchor fails loudly, which is the signal to re-audit the
patch. application is idempotent, and `fetch` re-verifies it the way
it re-verifies the digest. a formatless pin admits no patch: its one
output is the content-addressed file, and editing it fails its own
digest forever.

`exec` resolves only to pinned or staged bytes under `o/`, never a
`PATH` lookup. a project may run a tool it pinned; it cannot run
whatever happens to be installed. together: building an untrusted
repo cannot phone home and cannot run a host binary, and both halves
of the external surface are greppable.

two frays in the pin grammar are open:

- **the landing name comes from the url's tail.** that is why url-name
  validation exists, and why an on-disk name is coupled to a server's
  path layout. the positional answer is `3p/tl/tl_pin.tl` plus
  `tar.gz` landing at `o/3p/tl/tl.tar.gz`, with an optional `output`
  field for an archive whose inner layout makes the name matter.
- **integrity has two spellings**, flat `sha256` and the `platforms`
  table, so one committed file can be written twice and disagree with
  itself. the answer is to keep `platforms`, with `*` as the
  single-platform case, and refuse the other with a pointer.

the version stamp follows the same posture. `git describe` is not
available to a build. both halves are read with the literal reader:
the cosmos half from its pin, the cosmic half from a committed
`.version`, falling back to `COSMIC_VERSION` and then to `unknown`.
this repo commits no `.version`, because a release names itself by
the commit it tags, which is not a fact a file in that commit can
hold. the committed file keeps the enumerable-inputs property whole:
an environment variable alone makes two builds of one commit differ
by ambient environment.
