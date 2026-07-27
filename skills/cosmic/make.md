# Makefile-free Builds with `cosmic --make`

`cosmic --make` is cosmic's build system. a project is a directory tree:
filenames and directory positions declare intent, so there is no spec
file, no `rules.tl`, no `cook.mk` — and nothing to keep in sync with the
tree it describes.

```bash
cosmic --make check              # strict type-check the whole project
cosmic --make build              # compile every source into o/
cosmic --make test               # run *_test.tl against the compiled tree
cosmic --make fmt                # gate formatting
cosmic --make fetch              # resolve *_pin.tl (the only networked verb)
cosmic --make clean              # remove o/
cosmic --make build db/          # …or narrow any of them to a subtree
```

`--make` used to scan a directory and print a Makefile. it doesn't
anymore: the generated file needed a host make to be worth anything,
and it produced build files rather than builds. the verb grammar
replaced it outright.

## Verbs

| verb | what it does | today |
|---|---|---|
| `build` | compile the tree, then stage + embed → `o/bin/<name>` | ✅ |
| `check` | strict type-check (warnings are errors), in process | ✅ |
| `fmt` | formatting over every `.tl`; `--fix` rewrites | ✅ |
| `lint` | style: file length, cast justifications, test order | ✅ |
| `test` | run `*_test.tl` and report | ✅ |
| `example` | run `Example_*` functions and check their output | ✅ |
| `benchmark` | run every `*_benchmark.tl` | ✅ |
| `coverage` | tests + line coverage, ratcheted against `.coverage` | ✅ |
| `docs` | extract the doc index | ✅ |
| `ci` | fmt, check, test, example, lint, coverage — the gate | ✅ |
| `clean` | remove `o/` | ✅ |
| `fetch` | resolve `*_pin.tl` — the only verb with a network | ✅ |
| `help` | list the verbs, and which are still planned | ✅ |
| `run` | build, then exec the artifact | planned |
| `enforce` | rerun the sandbox tests unsandboxed, where a skip fails | planned |
| `reproducible` `offline` | policy lanes over the graph | planned |

`cosmic --make help` prints this list, split the same way; it is the
one that cannot go stale.

every verb ends in a machine-readable verdict line and an exit code:

```
make: root=/home/you/myapp
check: PASS (12 files)
```

## The artifact

`cosmic --make build` produces `o/bin/<name>` — a fat binary that runs
on Linux, macOS, Windows, and the BSDs, with your project inside it.
the name is the project directory's, or the `cmd/<name>/` directory's:

```
myapp/
  main.tl                   → o/bin/myapp
  cmd/fetchit/main.tl       → o/bin/fetchit
  cmd/servit/main.tl        → o/bin/servit
```

layout is derived, never enumerated. one rule:

```
package module, import path P  →  /zip/P.lua
asset at relative path R       →  /zip/R
entry                          →  /zip/main.user.lua behind the wrapper
```

the zip root **is** the module root, so "path relative to the root =
import path" holds inside the artifact too — `require("db.query")`
resolves the same way at build time and at run time.

each `cmd/<name>` artifact carries the root packages plus its own
subtree, and nothing from a sibling `cmd/` — the same boundary the
validator refuses imports across. `testdata/` is never embedded; that
is its only job. tests and `.d.tl` declarations do not ship either.

**the base is stripped to a positive floor, and there is no opt-out.**
what survives is cosmic's compiled standard library, the TLS roots and
zoneinfo, and `.args`. what goes is the toolchain: the Teal compiler,
the type declarations, cosmic's own `.tl` sources, the docs index, the
skills, the build rules. so `require("cosmic.json")` works in your
artifact and `require("tl")` does not — an artifact is a program, not a
copy of the thing that built it. a project that wants Teal at runtime
vendors it, and it ships because the project's own tree provides it.

builds are reproducible: entries carry a fixed mtime
(`SOURCE_DATE_EPOCH`, else the 1980 DOS floor) rather than the staging
file's, so two builds of one tree in two different directories are
byte-identical.

a build narrowed with paths compiles only what you selected and stops
there — half a tree cannot make a whole artifact.

## Test isolation

each test gets its own scratch directory *inside its own build step* —
`TEST_TMPDIR` points at a fresh `mkdtemp` under `o/<test>.test.tmp.d`,
not at a shared `/tmp`. tests cannot collide through the temp
directory, on any platform.

this applies to compiles too, and there it is about correctness rather
than speed: a strict compile type-checks against the modules it
imports, so changing a module's contract recompiles its importers. an
incremental build catches a broken contract exactly like a clean one.

a test likewise re-runs only when something it **imports** changes.
cosmic follows `require()` edges to compute each closure, so editing a
module no test imports re-runs nothing:

```bash
$ cosmic --make test          # edit a module only db/a_test.tl imports
test o/db/a_test.tl.test cosmic o/db/a_test.lua --deps o/db/init.lua ;
```

the closure after `--deps` is exactly what the fence grants. it is
named there for that purpose and never handed to the child.

with `COSMIC_FENCE=1` on a Landlock host that becomes enforced rather
than merely arranged: a test may write only its own step's directory,
and reads are the compiled tree plus its own source directory (which is
where `testdata/` lives, so fixtures need no special grant). the flag is
opt-in until the canary in the enforce lane has proven the denial on a
real kernel.

## Pins

a `*_pin.tl` declares an external asset. it is **data, not code**:

```teal
-- 3p/lpeg/lpeg_pin.tl
return {
  url = "https://example.test/lpeg-{version}.tar.gz",
  version = "1.0.2",
  sha256 = "9b0f0a...",
}
```

`cosmic --make fetch` resolves it; nothing else does. the file is
lexed and matched against a literal grammar — never loaded, never
compiled, never called — so a call, a concatenation, a bare variable, a
statement before the `return`, or anything after the table is refused
by name:

```
make: 3p/lpeg/lpeg_pin.tl:2: a pin holds literals only; found 'os' (no variables, calls or concatenation)
```

`url` and `sha256` are both required: a pin without a digest is a
download. bytes that do not hash to the pin are **never written**, so a
build either runs on the bytes you named or does not run. `{version}`
substitution is the one templating the grammar allows, which makes a
bump a one-line diff. the fetched asset lands under `o/`, mirroring the
pin's position and named by the url
(`3p/lpeg/lpeg_pin.tl` → `o/3p/lpeg/lpeg-1.0.2.tar.gz`) — nothing
generated belongs in the tree. a pin may also declare a `format`
(`zip` or `tar.gz`) with `strip_components`, and is then unpacked
beside its archive *after* the digest matches.

`fetch` is the only verb with a network, and that is structural: it is
the only part of `--make` that can open a socket at all. a project
whose pin points at an unreachable host still builds — building is not
fetching. re-running `fetch` when the bytes are already there and
already hash correctly touches no network at all.

## The engine

`check`, `clean` and `fetch` run in process. `build`, `test` and `fmt`
run on a dependency graph, so they are incremental and parallel — and
that needs a make binary. **cosmic carries one.** it extracts itself to
`o/make` the first time you need it, so a fresh clone on a machine with
no toolchain builds:

```bash
cosmic --make build     # nothing installed, nothing fetched
```

PATH is never searched. a build whose engine came from whatever the
host had installed is a build nobody can reproduce; the engine is
pinned inside the binary, or named with `COSMIC_MAKE=/path/to/make`,
never guessed. `COSMIC_JOBS` overrides the job count, which otherwise
follows `nproc`.

two files land in `o/` and make reads both:

- **`o/cosmic.mk`** — the rules. constant, byte-identical for every
  project, shipped inside the cosmic binary. no rule is ever generated.
- **`o/project.mk`** — the facts, generated: **only variable
  assignments**, the file lists the walk produced.

every recipe line is whitespace-split argv whose first word is a cosmic
verb (`compile`, `copy`, `test`, `tee`, …), run through `cosmic -c`. no
quoting, no expansion, no pipes, no redirects — the build's whole
capability surface is that vocabulary, and make echoes each line as it
runs it. the trailing `;` you will see is load-bearing: make execs a
line it judges shell-free itself, without consulting `SHELL`, so
without it cosmic would never see the line at all.

## The project model

| marker | declares |
|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package — compiled, checked, formatted |
| `main.tl` at the root | the project's binary |
| `cmd/<name>/main.tl` | one binary per subdirectory |
| `*_test.tl` | a test |
| `*_example.tl` | an example |
| `*.d.tl` | type-only; on the include path, never embedded |
| `*_pin.tl` | a pinned external asset |
| `*_benchmark.tl` | a benchmark |
| `*_gen.tl` | a generation unit — runs BEFORE the graph, writes inputs |
| `cmd/<name>/embed_gen.tl` | a binary's payload generator — runs AFTER |
| `embed/**` | payload, staged at the artifact root |
| `testdata/` | test fixtures; never embedded |
| `_<dir>/` | internal: importable only from within its container |
| everything else | an asset, embedded at its relative path |

**import path = path relative to the root**, `/` → `.`, extension
dropped. `pkg/db.tl` is `require("pkg.db")`; `pkg/init.tl` is
`require("pkg")`. the project root is the module root — including
inside the artifact, where the zip root is the module root too.

`.lua` sources are first-class. `foo.tl` beside `foo.lua` is an error,
not a precedence rule.

what the walk never sees: dot-prefixed entries (`.git`, `.github`), the
build directory `o/`, and anything a `.cosmicignore` pattern matches.
`.cosmicignore` holds one glob per line, `#` comments; a pattern matches
a whole relative path or a bare name, so `build/`, `*.log`, and `vendor`
all read the way they behave.

```
myapp/
  main.tl                   → o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  schema.sql                asset
  3p/lpeg/lpeg_pin.tl       cosmic --make fetch
```

## The root

the root is the current directory. `--make` never searches upward for
it — a build that guesses which project it is in is a build that writes
into the wrong tree. every run prints the root it used:

```
make: root=/home/you/myapp
```

the upward search exists only to refuse. running from inside a project
names the likely root and the command to run:

```
make: ambiguous root: /home/you/myapp/db is inside a project rooted at /home/you/myapp
make: run it from that root: cd /home/you/myapp && cosmic --make check
make: or name this one: COSMIC_MAKE_ROOT=/home/you/myapp/db cosmic --make check
```

a directory declares itself a root with `main.tl`, a `cmd/<name>/main.tl`,
or a `.cosmicignore`. a directory of `.tl` files is a package inside some
project, not a root. `COSMIC_MAKE_ROOT` names one explicitly, for
callers that cannot `cd`.

## Validator errors

these run before anything else, and all of them run — a project with
three problems reports three:

```
make: cosmic/fs.tl: reserved import path 'cosmic.fs'; 'cosmic' is the standard library every artifact is built on. define cosmic/init.tl to provide the whole namespace, or rename this file
make: pkg/a.tl: duplicate import path 'pkg.a'; also defined by pkg/a.lua
make: cmd/servit/main.tl: imports 'cmd.fetchit.main'; cmd/fetchit is private to its own binary
make: other.tl: imports 'pkg._priv.x', which is internal to 'pkg/'
make: cmd/nomain: no entry; expected cmd/nomain/main.tl
make: my notes.tl: path contains whitespace; recipe lines are whitespace-split argv
make: weird&name.tl: path contains a shell metacharacter: &
```

the last two are worth stating plainly: recipe lines are whitespace-split
argv with no quoting anywhere, so a space in a filename is refused rather
than escaped. a legitimate `my notes.tl` is rejected, by name.

the first one has an escape hatch, and it is deliberate. `cosmic` and
`tl` are ordinary Lua trees that happen to ship in the base, so a
project may **provide** either outright by defining the namespace's root
module — `cosmic/init.tl`, or `tl.lua`. claim it and the whole namespace
is yours: the artifact drops the base's copy, so one definition ships
instead of two. claiming `cosmic` means answering everything the runtime
requires of it, including `cosmic.searcher`, which the entry wrapper
loads before your `main.tl` runs. `cosmo` (a native binding) and
`main.user` (the wrapper's slot) cannot be claimed at all.

## Selection

paths select which files a verb acts on, several accepted, globbed by
your own shell:

```bash
cosmic --make check db/
cosmic --make test pkg/*/db_test.tl      # your shell expands it
```

selection changes which files run, never what the project is: the model
is always scanned whole, so a partial run resolves imports exactly the
way a full one does. a selection matching nothing is an error, not a
zero-file pass.

on the graph verbs, a selection travels as a make variable override, so
no rule knows about it — which is what lets the rules file stay
constant.
