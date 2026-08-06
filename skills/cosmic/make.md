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
| `coverage` | tests + line coverage, ratcheted against `.cosmic-coverage` | ✅ |
| `docs` | extract the doc index | ✅ |
| `ci` | fmt, check, example, lint, coverage — the gate; tests run once, instrumented, in `coverage` | ✅ |
| `clean` | remove `o/`, sparing `o/bootstrap` | ✅ |
| `fetch` | resolve `*_pin.tl` — the only verb with a network | ✅ |
| `help` | list the verbs, and which are still planned | ✅ |
| `run` | build, then run a source path against the built tree | ✅ |
| `enforce` | rerun the sandbox tests unsandboxed, where a skip fails | planned |
| `reproducible` `offline` | policy lanes over the graph | planned |

`cosmic --make help` prints this list, split the same way; it is the
one that cannot go stale.

every verb ends in a machine-readable verdict line and an exit code:

```
make: root=/home/you/myapp
check: PASS (12 files)
```

`clean` spares `o/bootstrap` on purpose: that is the verified copy
`bin/cosmic` fetched from the pin, and removing it makes the next
command reach for the network. cleaning a build should not have network
consequences.

## Converge

a gate verb's result is a statement **about a toolchain**, and a
project that defines the `cosmic` namespace builds its own. run `fmt`
under the pinned release and it formats with the release's formatter —
so a formatter fix would pass its own gate while shipping broken.

so a gate verb (`fmt`, `check`, `lint`, `test`, `example`, `coverage`,
`ci`) **builds first**, and if what it built is not the binary
currently running, re-execs into it with the original argv. you will
see the build scroll past before the stage does. this is the one
behavior you will actually observe that no other build tool does:

```
$ cosmic --make ci
make: root=/home/you/cosmic
build: PASS (377 files, 1 binary)
make: root=/home/you/cosmic        # ← the re-exec, now under the new binary
fmt: PASS (377 files)
...
ci: PASS (5 stages)
```

it terminates because the build is content-addressed — `o/bin/<name>`
is replaced only when its bytes change, so "did that change anything"
is a question the filesystem answers. **two generations is the cap**; a
third would mean the build is not a fixpoint, and that is a loud
`not a fixpoint` failure rather than a spin.

none of this happens in an ordinary project: your artifact is not the
tool that gates it, so there is nothing to converge to and the
machinery does nothing at all.

## The artifact

`cosmic --make build` produces `o/bin/<name>` — a fat binary that runs
on Linux, macOS, Windows, and the BSDs, with your project inside it.
the name is the `cmd/<name>/` directory's; a root `main.tl` is refused,
so a binary is never named after the checkout directory:

```
myapp/
  cmd/myapp/main.tl         → o/bin/myapp
  cmd/fetchit/main.tl       → o/bin/fetchit
  cmd/servit/main.tl        → o/bin/servit
```

layout is derived, never enumerated. one rule:

```
package module, import path P  →  /zip/P.lua
payload at embed/R             →  /zip/R
entry                          →  /zip/main.user.lua behind the wrapper
```

the zip root **is** the module root, so "path relative to the root =
import path" holds inside the artifact too — `require("db.query")`
resolves the same way at build time and at run time.

these `/zip/...` paths hold inside tests too: `--make test` runs tests
under a runner carrying the root `embed/` payload (`o/.testrun/cosmic`),
so `/zip/R` resolves in a test exactly as in the artifact. a
per-binary `cmd/<name>/embed/**` is the exception — one artifact's
private cargo — covered by spawning the built `o/bin/<name>` (see
`cosmic --docs guide.testing`).

each `cmd/<name>` artifact carries the root packages plus its own
subtree, and nothing from a sibling `cmd/` — the same boundary the
validator refuses imports across.

**shipping is opt-in.** an artifact carries its modules and `embed/**`,
and nothing else — a file that is merely IN the repo is not IN the
binary. so `docs/`, a `Makefile`, a stray `notes.md` and `testdata/`
all stay behind without anyone excluding them, and a `schema.sql` your
program needs becomes `embed/schema.sql`: one `git mv`, and the move
IS the declaration. tests and `.d.tl` declarations do not ship either.

there is no un-ship knob because there is nothing to un-ship. what an
artifact contains is greppable from the tree — `ls embed/` plus the
module set — the same way its network and exec surfaces already are.

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

a build narrowed with paths names BINARIES, not sources: the whole
tree still compiles, because a selected build must stage exactly what a
full one would. half a tree cannot make a whole artifact.

## Test isolation

each test gets its own scratch directory *inside its own build step* —
`TEST_TMPDIR` points at a fresh `temp_dir` under `o/<test>.test.tmp.d`,
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
record o/db/a_test.tl.test
```

that one line is the whole output: make runs with `-s`, so it echoes
nothing, and each step announces itself as its verb plus the path it
writes. the recipe behind it still names the import closure after
`--deps` — that closure is exactly what the fence grants, named there
for that purpose and never handed to the child.

the fence is **ON by default**; `COSMIC_FENCE=0` opts out. on a
Landlock host it is enforced by the kernel rather than merely arranged:
a test may write only its own step's directory, and reads are the
compiled tree plus its own source directory (which is where `testdata/`
lives, so fixtures need no special grant). on a host without Landlock
the grants are computed and cannot be enforced, so the step runs
unfenced — which is why CI asserts a real denial rather than trusting
that the mechanism ran.

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
verb (`compile`, `copy`, `record`, `tee`, …), run through `cosmic -c`.
no quoting, no expansion, no pipes, no redirects — the build's whole
capability surface is that vocabulary. make runs silently (`-s`) and
the driver prints one short line per step instead. the trailing `;` in
the rules is load-bearing: make execs a
line it judges shell-free itself, without consulting `SHELL`, so
without it cosmic would never see the line at all.

## The project model

| marker | declares |
|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package — compiled, checked, formatted |
| `cmd/<name>/main.tl` | one binary per subdirectory, named `<name>` |
| `main.tl` at the root | classifies as an entry, but is **refused**: a binary is named by its `cmd/<name>/`, never the checkout dir |
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
| everything else | an ordinary part of the project; never embedded |

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
  cmd/myapp/main.tl         → o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  embed/schema.sql          → /zip/schema.sql; in embed/ BECAUSE it ships
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

every verb answers about paths. most restrict: `V S` is the
`S`-restriction of a full `V`. two cannot, and say so instead of
accepting a path and ignoring it — `clean` removes the build directory
and `ci` is a verdict over the whole gate, so both refuse with the
reason. `coverage --baseline` refuses for the same reason one layer in:
a floor rewritten from partial data craters every row you did not
select.

paths are resolved against the model BEFORE anything is built, so a
typo costs a directory walk rather than a full rebuild.

on the graph verbs, a selection travels as a make variable override, so
no rule knows about it — which is what lets the rules file stay
constant.

## Machine-readable output

four things leave a run for something other than a person to read, and
they are one grammar, owned by `cosmic.records`:

```
✓ cosmic/fs/init_test.tl (7 test functions)  12ms   row
19 checks: 18 passed, 1 failed                      summary
wall: 73148ms  slowest: _make/fixpoint_test.tl (…)  summary
test: FAIL (1 of 19 files)                          verdict
```

- **row** — one per target. the name is the SOURCE path, not a
  basename: eleven files in this tree are called `init_test.tl`, and a
  failing row you cannot resolve to a file costs a grep with eleven
  hits. the `(N …)` annotation counts what the target actually ran, so
  it appears on passing rows of the stages that run things and nowhere
  else.
- **summary** — the counts, in `o/<verb>-summary.txt`. it SURVIVES a
  failing stage (`.PRECIOUS`): the summary of a stage that failed is
  the one a consumer opens next, and `.DELETE_ON_ERROR` was deleting
  exactly that.
- **verdict** — the last line, and the one that survives truncation.
  `N unit` when everything passed, `M of N unit` when it did not, read
  from the summary the stage wrote rather than from the size of the
  file list.
- **exit codes** — `0` pass, `2` skip, anything else fail, everywhere.
  a skip is NOT a pass: a stage that stopped checking and said nothing
  is what the third code exists to make visible.

never launder a gate's status through a pipe (`--make ci | tail`
returns tail's status) — use `set -o pipefail`, or read the verdict
line.

the coverage floor is `.cosmic-coverage`, namespaced because a bare
`.coverage` is coverage.py's binary data file and cosmic targets
polyglot repos.

## Environment variables

**public** — a user or a CI step may set these, and their meaning is
part of the contract:

| variable | meaning |
|---|---|
| `COSMIC_FENCE` | `0` opts out of the derived sandbox. On by default |
| `COSMIC_JOBS` | build parallelism (default: nproc) |
| `COSMIC_MAKE_ROOT` | name the project root instead of using the cwd |
| `COSMIC_COVERAGE` | a DIRECTORY to dump `.cov` files into |
| `COSMIC_VERSION` | the `--version` stamp, when no `.version` is committed |
| `COSMIC_INSTRUMENTATION` | `1`/`true` emits timing spans to stderr |
| `COSMIC_LOG_LEVEL` | `cosmic.log`'s threshold |
| `COSMIC_NO_WELCOME`, `COSMIC_NO_REQUIRE_HINTS`, `COSMIC_FULL_TRACEBACK` | output knobs |
| `NO_COLOR`, `TERM`, `TMPDIR`, `HOME`, `PATH`, `XDG_*`, `SOURCE_DATE_EPOCH`, `CI` | third-party conventions cosmic honours rather than invents |

three more are set by hand, but by a person doing a specific job rather
than by anyone configuring a build: `COSMIC_ENFORCE=1` turns a sandbox
test that cannot enforce from a skip into a failure (CI's enforce lane
sets it), `GENTYPE_DEFS` points type generation at a cosmopolitan
checkout's `definitions.lua` to validate before a release is cut, and
`PERF_BIN` names which binary the process-spawning `_perf` scenarios
(`startup_*`, `embed_*`) exec — it does not select the binary the
harness itself runs under.

**internal** — the build sets these for its own children. Setting one
by hand is a way to confuse a build, not to configure it:
`COSMIC_EXEC_ROOT` (what `exec` may reach), `COSMIC_MAKE_GEN` (the
converge budget),
`TEST_BIN` / `TEST_TMPDIR` / `TEST_DIR` (set per test by the runner),
`TMP` (pointed at a step's scratch directory), `COSMIC_TL_CACHE_DIR`.

`COSMIC_MAKE` is the one that is both: the build passes it down, and
you may set it to name a make engine (see above). everything else
`COSMIC_`-prefixed and not in these tables is internal.

**`COSMIC_COVERAGE` carries two protocols under one name**, and this is
a wart, not a design: `1`/`true` means "collection is armed" (what the
coverage rules export), while any other value is the directory to dump
into (what `--test` sets per test). `cosmic.coverage.dir_from_env`
is the one reader that knows the difference, and anything treating the
variable as a path must go through it — reading it directly is how a
build came to create a directory named `1`.
