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
| `check` | strict type-check (warnings are errors), in process | ✅ |
| `build` | compile every source into `o/` | ✅ |
| `test` | build, then run `*_test.tl` and report | ✅ |
| `fmt` | `--check-format` over every `.tl` | ✅ |
| `clean` | remove `o/` | ✅ |
| `run` | build, then exec the artifact | planned |
| `regen` | run generation units | planned |
| `fetch` | resolve `*.pin.tl` — the only verb with network | planned |
| `ci` `coverage` `enforce` `reproducible` `offline` | policy lanes over the graph | planned |

`build` does not produce `o/bin/<name>` yet — the artifact (stage,
embed, stripping to the floor) is the next slice. what it does today is
compile the whole tree, strictly: nothing lands in `o/` that the type
checker rejected.

every verb ends in a machine-readable verdict line and an exit code:

```
make: root=/home/you/myapp
check: PASS (12 files)
```

## The engine

`check` and `clean` run in process. `build`, `test` and `fmt` run on a
dependency graph, so they are incremental and parallel — and that needs
a make binary. cosmic does not carry one yet, so name it:

```bash
COSMIC_MAKE=/path/to/make cosmic --make build
```

PATH is deliberately not searched. a build whose engine came from
whatever the host had installed is a build nobody can reproduce; the
engine is named or (once cosmic embeds one) pinned, never guessed.
`COSMIC_JOBS` overrides the job count, which otherwise follows `nproc`.

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
| `*.pin.tl` | a pinned external asset |
| `*.gen.tl` | a generation unit |
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
  3p/lpeg/lpeg.pin.tl       cosmic --make fetch
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
make: cosmic/fs.tl: reserved import path 'cosmic.fs'; cosmic, cosmo, tl and main.user name the standard library inside every artifact
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
