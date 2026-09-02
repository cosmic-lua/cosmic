# Verbs

the command surface: graph verbs that build something and policy verbs
that orchestrate them, for a contributor adding or changing a verb.

`--make help` lists the verbs before a project is opened:

```text
build [binaries…]   compile, generate, stage, embed: o/bin/<name>
check [paths…]      strict type-check only, in process
clean               remove o/, keeping o/bootstrap/
fetch [paths…]      resolve *_pin.tl; the only verb with a network
fmt [paths…]        --check fmt over every source (--fix rewrites)
test [paths…]       build the stage, run *_test.tl fenced against it
run <path> [args…]  build, then run that source against the tree
docs [paths…]       render the model's documented sources to o/docs
example [paths…]    run Example_* against the staged tree
benchmark [paths…]  run every *_benchmark.tl against the stage
lint [paths…]       style gate over every file the model sees
ci                  fmt, check, example, lint, coverage
coverage            tests with line coverage, ratcheted
enforce             planned
reproducible        planned
offline             planned
```

a planned verb is listed rather than hidden, so asking for one gets
"planned, not implemented" instead of "unknown option".

`run` takes paths, never binary names. a built `o/bin/<name>` is
already executable, so the binary form buys a rebuild and nothing
else, while the source form is what every caller in this repo needs.
`run <name>` refuses, naming `o/bin/<name>`.
[resolution.md](resolution.md) defines "against the tree".

`check` runs the checker in process against the project model, so it
needs nothing installed and reports on the same file list every other
verb uses. it is incremental against the graph: a file whose compiled
output is up to date against the compile rule's own inputs is a check
that already ran, so `check` skips it. validation comes first and is
fatal, because a colliding import path or an unsplittable filename
turns into a confusing cascade from the type checker, or nothing.

`lint`'s file set is the model's: every file the walk finds, which is
the tracked-shaped set minus `o/` and minus `.cosmicignore`, with no
`git ls-files`. it reads bytes, so it sees a `.md`, a `.mk` and a
`.yml`, applies the 500-line cap to every file, and is a verb of its
own rather than a stage of `check`.

`docs` renders every documented source to `o/docs/<path>.md` in
process: modules, entries and `.d.tl` declarations, not tests or
examples. the file set comes from the model, so a new directory
cannot be missing from the site silently.

`fetch` prints `fetch <url>` per download. a satisfied pin fetches
nothing, and CI's `repro` lane runs `fetch` twice to assert it.

## the selection law

**selection names targets of the verb's own kind and never changes
what a target means.** `test` states it as "selection changes which
tests run, never what gets staged". `build`'s targets are binaries,
so `build cmd/foo` (or `build foo`) builds foo: the full pipeline,
staging what a full build stages, never a narrowed compile. a source
path is refused, pointing at `check`, whose targets are sources.

**every verb answers about paths, and answers first.** `V S` is the
`S`-restriction of a full `V`. a verb with no such restriction refuses
a path and names why: `clean` removes the build directory, `ci` is a
verdict over the whole gate. accepting a path and ignoring it is the
one behaviour that teaches a spelling which does something else.
`_make/law.tl` holds this, and it runs against the scanned model
before the gate converges, so a typo costs a walk instead of a
rebuild.

## policy verbs

policy verbs orchestrate the graph and are never graph rules.

`ci` is a fixed order: `fmt`, `check`, `example`, `lint`, `coverage`.
each stage is gated by material: no examples, no `example` stage; no
tests, no `coverage` stage; no committed `.cosmic-coverage`, no
ratchet. zero configuration, and a fresh project does not fail on a
stage that had nothing to do. a baseline is input data, so it stays
committed; only generated things are banned from the tree. `ci` runs
to the end rather than stopping at the first failure, because a gate
that reports one problem per run costs a round trip per problem.

there is no separate `test` stage in `ci`. `coverage` runs the same
test recipe with collection on, and its ratchet summary passes or
fails a failing test the way a plain run would. a second,
uninstrumented pass bought the gate only wall-clock: 157 s summed for
the plain lane against 351 s for the instrumented one. `--make test`
alone stays the fast, uninstrumented developer loop.

`ci` prints one line when `HEAD` is not a descendant of
`origin/main`: CI checks out a synthetic merge commit, so a branch
that passes locally can fail once merged. the probe calls `git` with
a timeout and never changes the exit code, because `main` advances
constantly and failing here would make `ci: PASS` unreachable.

in a project that builds its own toolchain, a gate verb builds first
and re-execs into what it built, capped at two generations, with a
loud `not a fixpoint` if a third would be needed. an ordinary project
has nothing to converge to, and `_make/converge.tl` does nothing.

## the verdict line

every verb ends in a machine-readable verdict line and an exit code.
`_tool/records.tl` holds the one grammar:

```text
✓ cosmic/fs/init_test.tl (7 test functions)  12ms   <- row
19 checks: 18 passed, 1 failed                      <- summary
test: FAIL (1 of 19 files)                          <- verdict
```

the verdict is the record that survives a truncated log. `ci`
grades the summaries its own stages wrote and ends with `ci: PASS` or
`ci: FAIL (stages)`. the stage removes the previous summary before
make runs, so a run that dies in `compile` cannot report the last
run's counts under this run's `FAIL`.

## the gate needs no git

each `git` exec inside a recipe is host surface, and one new recipe
that shells to git re-acquires the whole apparatus: `safe.directory`
in every lane, `fetch-depth: 0` for a describe. so `lint` discovers
files from the model, the version stamp reads a committed `.version`,
and the only `git` a verb calls is `ci`'s merge-base notice, which
never fails the gate. `docs.yml`'s push is a real git operation and
stays a workflow step. the exit criterion: `bin/cosmic --make ci`
passes in a container with no git installed, and the fence refuses
`git` as a recipe child.

## the lanes converge on the verbs

each `pr.yml` lane still carries logic as YAML-embedded bash, which is
the orchestration the design assigns to policy verbs. logic in YAML is
unrunnable locally, unversioned by the verbs' tests and per-forge. the
target is that every job is checkout, setup and one verb:

| YAML today | destination |
|---|---|
| the netns bring-up around the gate | the `offline` verb; the bring-up is already cosmic code |
| build, copy, rebuild elsewhere, `cmp` | the `reproducible` verb |
| the fence lane and its canary | the `enforce` verb, printing its own evidence |
| `--make fetch` twice, asserting the second fetches nothing | `fetch`'s own idempotence check |
| "dump failing test output": `find` and `cat` over `.got`, `.out`, `.err` | the reporter. `--report` prints a summary, not the failing tests' captured output, and every other consumer of the gate lacks it too |

the reporter piece comes first: it is verb-independent, it shrinks
every lane, and it improves the local run today.
