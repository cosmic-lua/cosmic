# Why cosmic is shaped this way

the design behind the tree: one executable zip, two binding layers with
generated types, ratchets instead of reviews, tests that run because
they are defined, and an error doctrine the checker enforces. for a
contributor who wants the reasons before the rules.

## one executable zip

the cosmic binary is a native executable with a zip archive appended.
Cosmopolitan Libc maps the archive at `/zip/` at run time, so the
Lua runtime, the Teal compiler, the compiled library, the type
declarations, the doc index and the help text travel as one file that
runs on six operating systems.

the zip root is the module root. that is the same rule the repository
follows, so `require("cosmic.fs")` resolves to `cosmic/fs/init.tl` in the
tree and to `/zip/cosmic/fs.lua` in the artifact, and a module's
position needs no second declaration to ship. names that are not
modules carry a leading dot (`.types/`, `.docs/`, `.tl/`), which keeps
them out of the module root.

what a binary carries is a thing its unit says. an artifact holds its
compiled modules plus what `cmd/<name>/embed_gen.tl` names, and nothing
else. cosmic's own generator names `sys/`, the four shipped kinds of
page under `docs/`, the compiler, the type declarations and the graph
engine. shipping is opt-in, so a repository full of files that are
about the project (`docs/dev/`, `_perf/`, `_make/testdata/`) cannot
leak into the artifact by existing
([D15](../../decisions/d15-shipping-is-opt-in.md)). the base under the
payload is stripped to a keep-list too: compiled `cosmic/**`, TLS
roots, zoneinfo, `.args`. a base that grows a directory cannot start
shipping it silently.

## two binding layers, one source of types

`cosmo.*` is the C binding surface Cosmopolitan exposes: `cosmo.unix`,
`cosmo.path`, `cosmo.lsqlite3` and the rest. it returns what C returns.
`cosmic.*` is the typed Teal layer over it: honest failure types,
resource cleanup, one error shape per module, and doc comments the
binary renders. user code imports `cosmic.*`. a library internal is the
one place `require("cosmo")` belongs, because a wrapper has to call
what it wraps.

the `cosmo.*` declarations are generated and never committed. the
source of truth is `tool/net/definitions.lua` in cosmic-lua/cosmopolitan,
embedded in the pinned cosmos `lua` binary. `_types/gentype.tl` parses
its annotations into Teal records; `_types/gentl.tl` extracts the
public compiler API from the pinned tl source. a generated file in the
tree needs three things: a drift test to prove it still matches its
generator, a command to regenerate it, and a reviewer who notices when
a diff is output rather than intent. generating into `o/_types/types_gen/`
retires all three. a `cosmo.*` change shows up as the pin bump that
caused it. the cost is stated: a fresh clone cannot resolve `cosmo.*`
until it has fetched and built once, and an editor needs that
directory on its include path.

## ratchets, not reviews

a promise that depends on a reviewer noticing holds until the reviewer
is busy. `_build/` holds the promises this repository makes about
itself as ratchets instead. each pairs three parts: a measurement of
the tree, a committed floor, and a test that fails when the two
disagree.

| surface | measurement | committed floor |
|---|---|---|
| the public module surface | `_build/public_surface.tl` | `_build/public_surface_baseline.tl` |
| `as` casts | `_build/casts.tl` | `_build/casts_baseline.tl` |
| nil-admitting returns | `_build/nil_returns.tl` | `_build/nil_returns_baseline.tl` |
| line coverage | the coverage stage | `.cosmic-coverage` |
| derived regions of committed pages | `_docs/derive.tl` | the fences and tables in the pages |
| every code fence in a page | `_build/snippets_test.tl` | the page itself |
| the workflow files | `_build/workflows_test.tl` | the copies of the container block |

a floor moves only when someone rewrites it and says why in the same
change, so growth is a diff a reviewer reads rather than a drift
nobody sees. the same shape holds in both directions: the public
surface test fails on a name the tree has and the set lacks, and on a
name the set has and the tree lacks. `_build/ratchet.tl` is the one
markdown-table reader the document ratchets stand on, tested on its
own, because a ratchet is only as good as the reader under it. the
size report in `_build/size.tl` is the deliberate exception: goals
[G9](../../goals.md) says growth is surfaced, not refused, so it has no
threshold and no failing exit.

## how a test runs

a test is a `*_test.tl` file, and a case is a top-level `local
function test_*` inside it. defining the case enrols it. the compile
step reads the file, and when its shape is runner mode, appends a
generated tail that hands every case to `cosmic.test.main` in source
order. the checker checks what runs, the chunk runs what is defined,
and no line number moves. the tradeoff behind enrolment by definition
is [D29](../../decisions/d29-tests-run-because-defined.md).

`--make test` builds the project's binaries and puts `o/bin` first on
the child `PATH`, with `TEST_BIN` naming the directory, so a test can
spawn the binary under test. it compiles each test to `.lua`, runs it
with its own `TEST_TMPDIR`, and records exit code, stdout and stderr as
`.got`, `.out` and `.err` beside the compiled file. `--report`
aggregates the `.got` files into the verdict line. a test's
prerequisites are its transitive import closure as built paths, taken
from the model; nothing is declared. `--make ci` runs the tests once,
instrumented, inside the coverage stage, and the ratchet judges the
result.

an example is a test with a different contract: an `Example_*`
function prints, and the runner compares stdout with the `-- Output:`
block. a page that shows output derives its fence from an example, so
the runner is the one authority on what code prints. a benchmark is a
`Benchmark_*` function the runner times on its own.

## what the error doctrine does to the code

the type must admit failure. a fallible value is `T | nil, string`; a
fallible effect is `boolean, string`; a module whose failures carry
structure returns its own error record in slot 2
([D24](../../decisions/d24-structured-failures.md)); an infallible
function returns a bare value. library code never throws. the
exemptions are named and each site says why: `cosmic.check`'s
assertions, the CSPRNG's throw on failure, a justified `assert` on an
impossible `cosmo.*` nil, and the three boundaries where a throw is
the only channel
([D23](../../decisions/d23-check-throws.md),
[D30](../../decisions/d30-throw-exit-boundaries.md)).

the doctrine shows up in the codebase as shape. a caller of a fallible
value has to narrow the nil before it indexes, so the checker enforces
the doctrine at every use site, and the carried tl patch teaches it
the guards Lua programmers write. a fallible return has exactly two
slots, and the `fallible-returns` lint refuses a third, so extra facts
ride on the value's record. a cast needs a justification comment the
`cast-justify` lint reads, and the cast count is a committed ceiling.
one module, one pattern, so a reader who has seen one function in a
module has seen its error shape. the shapes and the worked examples
are `cosmic --docs reference.errors` and `cosmic --examples errors`,
and `cosmic --docs explanation.errors` carries the argument in full.
