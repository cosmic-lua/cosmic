# `--make` reference

the facts of `cosmic --make`: its verbs, the project model, the root
rule, the messages, the output grammar and the environment variables.

`cosmic --docs howto.build` has the steps. `cosmic --docs
explanation.build` says why.

## Verbs

`cosmic --make <verb> [paths...]`. `cosmic --make help` prints the
same list, split the same way.

| verb | what it does | today |
|---|---|---|
| `build` | compile the tree, then stage and embed into `o/bin/<name>` | shipped |
| `check` | strict type check, warnings are errors, in process | shipped |
| `fmt` | formatting over every `.tl`; `--fix` rewrites | shipped |
| `lint` | style: file length, cast justifications, test order | shipped |
| `test` | run `*_test.tl` and report | shipped |
| `example` | run `Example_*` functions and check their output | shipped |
| `benchmark` | run every `*_benchmark.tl` | shipped |
| `coverage` | tests with line coverage, ratcheted against `.cosmic-coverage`; `--baseline` rewrites the floor | shipped |
| `docs` | extract the doc index | shipped |
| `ci` | the gate: `fmt`, `check`, `example`, `lint`, `coverage`; tests run once, instrumented, in `coverage` | shipped |
| `clean` | remove `o/`, sparing `o/bootstrap` | shipped |
| `fetch` | resolve `*_pin.tl`; the only verb with a network | shipped |
| `help` | print the verb list | shipped |
| `run` | build, then run one source path against the built tree | shipped |
| `enforce` | rerun the sandbox tests unsandboxed, where a skip fails | planned |
| `reproducible` `offline` | policy lanes over the graph | planned |

`check`, `clean` and `fetch` run in process. `build`, `test`, `fmt`,
`lint`, `example`, `benchmark` and `coverage` run on the dependency
graph: incremental and parallel.

a gate verb (`fmt`, `check`, `lint`, `test`, `example`, `coverage`,
`ci`) builds first. when the built binary differs from the running one,
the verb re-execs into it with the same argv. two generations is the
cap; a third fails with `not a fixpoint`. in a project that does not
define the `cosmic` namespace the built artifact is never the running
binary, so no re-exec happens.

`ci` runs a stage only when the project has material for it: no tests,
no `coverage` stage; no `*_example.tl`, no `example` stage. no committed
`.cosmic-coverage`, no ratchet.

flags belong to one verb each:

```text
make: --fix belongs to `fmt`, not '<verb>'
make: --baseline belongs to `coverage`, not '<verb>'
make: --baseline rewrites the whole floor; it takes no paths
```

`run` takes exactly one path, first, and passes the rest to the script:

```text
make: run takes exactly one path
make: run takes a path first, got '<arg>'
make: run takes a path, not a binary name; build it and run o/bin/<name>
```

`build` prints a hint after it passes: `next: run cosmic --make ci`,
because `fmt` and `lint` did not run.

## The project model

| marker | declares |
|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package module: compiled, checked, formatted |
| `cmd/<name>/main.tl` | one binary per subdirectory, named `<name>`, at `o/bin/<name>` |
| `main.tl` at the root | classifies as an entry and is refused: a binary is named by its `cmd/<name>/`, never by the checkout directory |
| `*_test.tl` | a test |
| `*_example.tl` | an example |
| `*_benchmark.tl` | a benchmark |
| `*.d.tl` | type-only; on the include path, never embedded |
| `*_pin.tl` | a pinned external asset, resolved by `fetch` |
| `*_gen.tl` | a generation unit; runs before the graph, writes inputs, owns `o/<its path minus .tl>/` |
| `cmd/<name>/embed_gen.tl` | that binary's payload generator; runs after the graph |
| `embed/**` | payload, staged at the artifact root; `cmd/<name>/embed/**` is one binary's private payload |
| `testdata/` | test fixtures; never embedded |
| `_<dir>/` | internal: importable only from within its container |
| everything else | an ordinary part of the project; never embedded |

`.lua` sources are first-class. `foo.tl` beside `foo.lua` is an error.

the walk never sees dot-prefixed entries (`.git`, `.github`), the build
directory `o/`, or anything a `.cosmicignore` pattern matches.

`.cosmicignore` holds one glob per line; `#` starts a comment. a
trailing `/` is dropped, so `build/` and `build` mean the same. a
pattern matches the whole relative path or the bare name.

a project laid out under every marker:

```text
myapp/
  cmd/myapp/main.tl         o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl          a test
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  embed/schema.sql          /zip/schema.sql
  3p/lpeg/lpeg_pin.tl       cosmic --make fetch
```

## Import paths

the import path is the path relative to the root, with `/` read as `.`
and the extension dropped. `pkg/db.tl` is `require("pkg.db")`;
`pkg/init.tl` is `require("pkg")`.

the project root is the module root. the zip root is the module root
too, so `require("db.query")` resolves the same way at build time and
inside the artifact.

## The root

the root is the current directory. `--make` never searches upward for
it. every run prints the root as its first line:

```text
make: root=/home/you/myapp
```

a directory is a root when it holds `main.tl`, a `cmd/<name>/main.tl`,
or a `.cosmicignore`. a directory of `.tl` files is a package inside
some project, not a root. `COSMIC_MAKE_ROOT` names a root explicitly
and skips both checks below.

a run from inside a project is refused, naming the root it found:

```text
make: ambiguous root: /home/you/myapp/db is inside a project rooted at /home/you/myapp
make: run it from that root: cd /home/you/myapp && cosmic --make check
make: or name this one: COSMIC_MAKE_ROOT=/home/you/myapp/db cosmic --make check
```

a run from a directory that declares nothing is refused:

```text
make: not a project: /home/you/notes
make: a project declares itself with main.tl, cmd/<name>/main.tl, or .cosmicignore
make: to build this directory anyway: COSMIC_MAKE_ROOT=/home/you/notes cosmic --make check
```

a root whose path holds whitespace or a make-significant character
(`$`, `(`, `)`, `:`, `=`, `%`) is refused:

```text
make: unusable project root: /Users/me/My Projects/thing
make: the path contains whitespace, and make prerequisites are whitespace-separated with no escape that survives
make: move or link the checkout to a path without spaces
```

a `COSMIC_MAKE_ROOT` that is not a directory fails with
`make: not a directory: <value>`.

## Validator errors

the validator runs before anything else, and every check runs: a
project with three problems reports three.

```text
make: cosmic/fs.tl: reserved import path 'cosmic.fs'; 'cosmic' is the standard library every artifact is built on. define cosmic/init.tl to provide the whole namespace, or rename this file
make: pkg/a.tl: duplicate import path 'pkg.a'; also defined by pkg/a.lua
make: cmd/servit/main.tl: imports 'cmd.fetchit.main'; cmd/fetchit is private to its own binary
make: other.tl: imports 'pkg._priv.x', which is internal to 'pkg/'
make: cmd/nomain: no entry; expected cmd/nomain/main.tl
make: my notes.tl: path contains whitespace; recipe lines are whitespace-split argv
make: weird&name.tl: path contains a shell metacharacter: &
```

a space or a shell metacharacter in a path is refused, never escaped.

`cosmic` and `tl` are reserved namespaces with one escape: a project
provides the whole namespace by defining its root module,
`cosmic/init.tl` or `tl.lua`. the artifact then drops the base's copy.
a project that claims `cosmic` answers everything the runtime requires
of it, including `cosmic.searcher`, which the entry wrapper loads before
`main.tl` runs. `cosmo` (a native binding) and `main.user` (the
wrapper's slot) cannot be claimed.

## Selection

paths after the verb select which files it acts on. several are
accepted. the shell expands globs.

- selection changes which files run, never what the project is. the
  model is scanned whole, so a partial run resolves imports exactly as
  a full one does.
- a selection matching nothing is an error:
  `make: nothing to do under: <path>`.
- a selection names targets of the verb's own kind. `build`'s targets
  are binaries, so `build cmd/foo` builds one binary and a source path
  fails with `make: build takes binaries; to type-check sources, use
  check`.
- a selected `build` still compiles the whole tree, because it stages
  exactly what a full build stages.
- `clean` and `ci` refuse paths: `make: clean takes no paths; it
  removes the build directory` and `make: ci takes no paths; it is the
  whole gate`.
- paths are resolved against the model before anything is built.
- on the graph verbs a selection travels as a make variable override.
  no rule knows about it.

## The artifact

`o/bin/<name>` is a fat binary for Linux, macOS, Windows, FreeBSD,
OpenBSD and NetBSD. its layout follows one rule:

```text
package module, import path P    /zip/P.lua
payload at embed/R               /zip/R
entry                            /zip/main.user.lua, behind the wrapper
```

- an artifact carries the root packages, its own `cmd/<name>/` subtree,
  the root `embed/**` and its own `cmd/<name>/embed/**`. it carries
  nothing from a sibling `cmd/`.
- tests, `*.d.tl` files, `testdata/` and every unlisted file stay
  out.
- the base is stripped to a positive floor: cosmic's compiled standard
  library, the TLS roots, zoneinfo and `.args`. the Teal compiler, the
  type declarations, cosmic's `.tl` sources, the doc index, the docs
  and the build rules are removed. `require("cosmic.json")` works in an
  artifact; `require("tl")` does not, unless the project's own tree
  provides it.
- zip entries carry a fixed mtime: `SOURCE_DATE_EPOCH` when set, else
  the 1980 DOS floor. two builds of one tree in two directories are
  byte-identical.
- a unit's output directory holds `embed/` (the staged payload) beside
  `base` (the runtime). a `base-<variant>` beside `base` ships the same
  staged payload as `o/bin/<name>-<variant>`.
- `--make test` runs tests under `o/.testrun/cosmic`, a runner that
  carries the root `embed/**`, so `/zip/R` resolves in a test.
  `cmd/<name>/embed/**` is not in the runner.

## Pins

a `*_pin.tl` is data: a `return { ... }` of literals, lexed against a
literal grammar and never loaded, compiled or called.

| field | meaning |
|---|---|
| `url` | required; `{version}` is substituted |
| `sha256` | required; the digest the bytes must hash to |
| `version` | substituted into `{version}` in `url` |
| `format` | `zip` or `tar.gz`; the archive is unpacked beside itself after the digest matches |
| `strip_components` | leading path components dropped when unpacking |

- anything but literals is refused by name: a call, a concatenation,
  a bare variable, a statement before the `return`, text after the
  table.

  ```text
  make: 3p/lpeg/lpeg_pin.tl:2: a pin holds literals only; found 'os' (no variables, calls or concatenation)
  ```

- bytes that do not hash to `sha256` are never written.
- the fetched file lands under `o/`, mirroring the pin's position and
  named by the url: `3p/lpeg/lpeg_pin.tl` fetches to
  `o/3p/lpeg/lpeg-1.0.2.tar.gz`. an archive unpacks beside it.
- `fetch` is the only verb that opens a socket. a `fetch` whose bytes
  are present and hash correctly touches no network. a project whose
  pin names an unreachable host still builds.

## The engine

- the graph verbs run on a make engine. cosmic extracts its own copy
  to `o/make` on first use. `PATH` is never searched. `COSMIC_MAKE`
  names another engine.
- `COSMIC_JOBS` sets the job count; the default is the processor count.
- `o/cosmic.mk` holds the rules. it is constant, byte-identical for
  every project, and shipped inside the binary at `/zip/cosmic.mk`.
- `o/project.mk` holds the facts: variable assignments only, including
  `srcdeps_<stem>`, each source's transitive import closure. it is
  output, never committed.
- every recipe line is whitespace-split argv run through `cosmic -c`.
  the first word is a verb from a closed vocabulary (`compile`, `copy`,
  `record`, `tee` and others). no quoting, no expansion, no pipes, no
  redirects. the trailing `;` in a rule is load-bearing: make execs a
  line it judges shell-free itself, without consulting `SHELL`.
- make runs with `-s`. the driver prints one line per step: the verb
  and the path it writes, as `record o/db/a_test.tl.test`.
- compiles are always strict: type check, then generate from the same
  checked AST. there is no flag to select it. a module whose contract
  changed recompiles its importers.

## Tests

- each test runs in its own build step with `TEST_TMPDIR` pointing at
  a fresh directory under `o/<test>.test.tmp.d`.
- a test re-runs only when a file it imports changes. cosmic follows
  `require()` edges to compute the closure. the recipe names that
  closure after `--deps`; the closure is what the fence grants, and it
  is never handed to the child.
- the fence is on by default. `COSMIC_FENCE=0` opts out.
- on a Landlock host the kernel enforces the grants. a test writes only
  its own step's directory. it reads the compiled tree plus its own
  source directory, where `testdata/` lives.
- on a host without Landlock the grants are computed and not enforced;
  the step runs unfenced.

## Output

every verb ends in a verdict line and an exit code. four things leave
a run in one grammar:

```text
✓ cosmic/fs/init_test.tl (7 test functions)  12ms    row
19 checks: 18 passed, 1 failed                       summary
wall: 73148ms  slowest: _make/fixpoint_test.tl (…)   summary
test: FAIL (1 of 19 files)                           verdict
```

- **row**: one per target. the name is the source path, not a
  basename. the `(N ...)` annotation counts what the target ran and
  appears only on passing rows of stages that run things.
- **summary**: the counts, in `o/<verb>-summary.txt`. its target is
  phony, so it is rewritten every run and survives a failing stage.
- **verdict**: the last line. `N unit` when everything passed,
  `M of N unit` when not, read from the summary the stage wrote.
- **exit codes**: `0` pass, `2` skip, anything else fail. a skip is not
  a pass.
- a pipe launders the status: `--make ci | tail` returns `tail`'s.

## The coverage floor

- the floor is `.cosmic-coverage` at the root: one row per file, no
  shared total line. its absence means no ratchet.
- `coverage --baseline` writes this run's exact measurement into every
  row, raises and drops alike, with no clamp.
- a rewrite that would lower more than half the committed rows is
  refused.
- with `.cosmic-coverage merge=union` in `.gitattributes`, a merge
  keeps both sides' rows. the ratchet reads a repeated path as its
  lower percentage and says how many rows it resolved that way. the
  next `--baseline` rewrites the file clean.
- `COSMIC_COVERAGE` carries two protocols. `1` or `true` means
  collection is armed; the coverage rules export that. any other value
  is the directory to dump `.cov` files into; `--test` sets that per
  test. `cosmic.coverage.dir_from_env` is the one reader that tells
  them apart.

## Environment variables

public. a user or a CI step may set these; their meaning is part of the
contract.

| variable | meaning |
|---|---|
| `COSMIC_FENCE` | `0` opts out of the derived sandbox; on by default |
| `COSMIC_JOBS` | build parallelism; default is the processor count |
| `COSMIC_MAKE_ROOT` | the project root, instead of the current directory |
| `COSMIC_MAKE` | the make engine to run; the build passes it down |
| `COSMIC_COVERAGE` | a directory to dump `.cov` files into |
| `COSMIC_VERSION` | the `--version` stamp, when no `.version` is committed |
| `COSMIC_INSTRUMENTATION` | `1` or `true` emits timing spans to stderr |
| `COSMIC_LOG_LEVEL` | `cosmic.log`'s threshold |
| `COSMIC_NO_WELCOME`, `COSMIC_NO_REQUIRE_HINTS`, `COSMIC_FULL_TRACEBACK` | output knobs |
| `NO_COLOR`, `TERM`, `TMPDIR`, `HOME`, `PATH`, `XDG_*`, `SOURCE_DATE_EPOCH`, `CI` | third-party conventions cosmic honours |

by hand. set by a person doing one job, not by a build configuration.

| variable | meaning |
|---|---|
| `COSMIC_ENFORCE` | `1` turns a sandbox test that cannot enforce from a skip into a failure |
| `GENTYPE_DEFS` | a cosmopolitan checkout's `definitions.lua` for type generation |
| `PERF_BIN` | the binary the process-spawning `_perf` scenarios (`startup_*`, `embed_*`) exec |

internal. the build sets these for its own children; setting one by
hand confuses a build.

| variable | meaning |
|---|---|
| `COSMIC_EXEC_ROOT` | what `exec` may reach |
| `COSMIC_MAKE_GEN` | the converge budget |
| `TEST_BIN`, `TEST_TMPDIR`, `TEST_DIR` | set per test by the runner |
| `TMP` | a step's scratch directory |
| `COSMIC_TL_CACHE_DIR` | the compiler's cache directory |

every other `COSMIC_`-prefixed variable is internal.
