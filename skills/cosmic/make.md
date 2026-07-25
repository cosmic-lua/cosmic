# Makefile-free Builds with `cosmic --make`

`cosmic --make` is cosmic's build system. a project is a directory tree:
filenames and directory positions declare intent, so there is no spec
file, no `rules.tl`, no `cook.mk` — and nothing to keep in sync with the
tree it describes.

```bash
cosmic --make check              # strict type-check the whole project
cosmic --make check db/          # …or just one subtree
cosmic --make check db/query.tl main.tl
```

`--make` used to scan a directory and print a Makefile. it doesn't
anymore: the generated file needed a host make to be worth anything,
and it produced build files rather than builds. the verb grammar
replaced it outright.

## Verbs

`check` runs today. the rest are named here because they are defined
and land in later slices — asking for one tells you where it stands:

| verb | what it does |
|---|---|
| `check` | strict type-check (warnings are errors) |
| `build` | check → compile → stage → embed → `o/bin/<name>` |
| `test` | build the stage, run `*_test.tl` against it |
| `fmt` | `--check-format` over the project (`--fix` to rewrite) |
| `run` | build, then exec the artifact |
| `regen` | run generation units |
| `fetch` | resolve `*.pin.tl` — the only verb with network |
| `clean` | remove `o/` |
| `ci` `coverage` `enforce` `reproducible` `offline` | policy lanes over the graph |

every verb ends in a machine-readable verdict line and an exit code:

```
make: root=/home/you/myapp
check: PASS (12 files)
```

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
cosmic --make check 'pkg/*/db_test.tl'   # your shell expands it
```

selection changes which files run, never what the project is: the model
is always scanned whole, so a partial run resolves imports exactly the
way a full one does. a selection matching nothing is an error, not a
zero-file pass.
