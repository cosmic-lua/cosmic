# Module resolution

which bytes answer `require("x.y")` in a process the build spawns, for
a contributor who changes `cosmic.searcher`, the module manifest or a
verb that runs project code.

[model.md](model.md) says import path = path relative to the root,
and the graph compiles every source to `o/<path>.lua`. neither
sentence is about run time. this chapter is.

## the rule

> **in a project, the tree answers. outside one, the binary does.**

precedence for a child the engine spawns:

1. the **build closure**: the exact files the graph produced for this
   target
2. the rest of the **build directory**: what the graph built for
   imports outside this target's closure
3. the rest of the **tree**, compiled strictly by `cosmic.searcher`
4. the running binary's payload (`/zip/**`)
5. Cosmopolitan's own (`/zip/.lua/**`)

layers 1 to 3 are the same answer at different costs. layers 1 and 2
are what the graph already built, so they are a cache and a freshness
guarantee, not a separate semantics. deleting `o/` changes how long a
require takes and not what it returns. that is what makes the rule
one sentence instead of a table.

layer 2 is not an optimization. without it every child
strict-compiles the dispatcher's own modules from source, because
they are outside any single test's closure: 2.3 s for one probe test
against 5 ms, paid per child. every verb that runs project code
compiles the whole tree first, so the files are there and current.

**layer 3 is strict**, and that is what earns it its position. a lax
compile ahead of the binary's checked bytes would let position decide
which compile mode you got. strict makes the layers agree by
construction, so "the tree wins" costs nothing but time. strict here
means type errors, not warnings. a module that does not type-check is
not one to run, so a type error fails the `require`. warnings pass:
warnings-as-errors is `--check types`'s contract, and inheriting it
here turns a shadowed local into a runtime failure of whatever
happened to require the file first. the gate stays the gate.

an artifact running as itself keeps its own order. a built binary
answers from its own zip no matter what the environment says.
`_make/artifact_test.tl` names its child's environment rather than
inheriting it, so an artifact test cannot be answered by the checkout
that built it. that is why the mechanism below is not `LUA_PATH`.

## what a child without a manifest resolves

a child with no manifest is an ordinary cosmic, which is what a
hand-run script is. its `package.path` names `/zip/?.lua` and
`/zip/?/init.lua` first, then Cosmopolitan's `/zip/.lua/`, then the
current directory, and `cosmic.searcher` last, which compiles a tree
`.tl` lax. so a bare child resolves a module to the running binary's
copy if it embeds one, else a committed `.lua`, else the lax-compiled
source. `o/` appears nowhere in that order.

three things follow for a build that spawns such a child, and the
manifest exists to prevent each of them. a generator whose helper the
binary embeds runs one generation of code for the generator and
another for the helper, so its first pass writes stale output and
reports `PASS`. a test scheduled and fenced against `o/greet/init.lua`
loads `./greet/init.tl` instead, so cosmic's tests test the binary's
modules and a user's tests test lax-compiled source, and nobody tests
the strict-compiled bytes that ship. a benchmark harness the binary
embeds measures the binary, not the tree, however it is invoked.

the lax half also costs a second compile of every module, cached by
content hash in a shared directory: `cosmic/_script_cache.tl` reads
`COSMIC_TL_CACHE_DIR`, then `XDG_CACHE_HOME`, then `TMPDIR`, landing
at `/tmp/cosmic-tl-cache-<uid>`.

## the closure is already in the line

`--deps` carries the transitive import closure, as built paths, on
every test, example, benchmark and coverage recipe. `_make/deps.tl`
computes it once for two consumers: the graph, for scheduling, and the
fence, for grants. resolution is the third. cosmic builds an `import
path -> file` map from those same paths and installs it as a searcher
ahead of everything else. nothing new is declared. the argument
positions stay the declaration.

an explicit map rather than a path prefix, for three reasons:

- **exact.** a prefix over `o/` also offers `o/x.tl.test.got`,
  `o/.coverage/**` and every other build dropping in the mirror. a map
  offers what the graph built and nothing else.
- **already fresh.** make made those exact files before the recipe
  ran. there is no window where a stale `o/` wins.
- **already fenced.** the paths are the read grants, so resolution
  cannot reach what the fence denies.

**the channel is `--modules <manifest>`.** the `record` step strips
`--deps` before it spawns the child, because a test that reads
`arg[1]` would otherwise find its own dependency list there. the
closure reaches the child as a file written beside the step's own
output, `<out>.modules`, inside the write grant the step already has,
and named on the command line. three line kinds:

```text
root  <absolute project root>
build <build directory, relative to the root>
mod   <import.path> <built file>
```

`cmd/cosmic/main.tl` scans the flag by hand at the top of the file,
before its first `require`. a module already in `package.loaded` is
never searched again, so anything required before the install would
be pinned to the binary's copy whatever the manifest said, and a test
of `_cli.args` would test `/zip`'s. `cosmic.searcher` is the one
module that stays the binary's, which is why it reads the manifest
with `io.open` rather than `cosmic.fs`. the searcher inserts itself
at index 2 of `package.searchers`, after `package.preload` and ahead
of the default file searcher, because beating `/zip` is the point.

**it travels in argv and does not inherit.** ten `_make/*_test.tl`
files spawn a cosmic against a different project root under `/tmp`.
carried in the environment, this repo's `o/` would answer `cosmic.*`
and `_make.*` while those children built unrelated projects. a
manifest named on one command line cannot leak into a grandchild. a
child that spawns a child and wants the same resolution passes it on
deliberately.

## layer 2 and the fence

layer 2 fires for imports no closure names, which is the class
`_make/deps.tl` cannot see: a computed require. `_perf/run.tl`'s
`load_module` is that case, `pcall(require, name)` with `name` off
argv, which is how every `_perf/bench/*_bench.tl` scenario loads. so
the fence has to grant reads it did not derive. for a test it does:
`_cli/grants.tl` gives `record` the whole project, with the reasons
written there. `run` and the generator pre-pass inherit the same
grant rather than having had the line drawn for them, which is an
open item below.

## three cases the closure does not cover by itself

**source generators run before the graph.** a `*_gen.tl` writes build
inputs, so nothing is compiled when it runs. the engine compiles the
generator's closure strictly into `o/` first, through the graph's own
`compile` step, then runs the generator with that closure as its
manifest. `_types/types_gen.tl`'s closure is about twenty files of
several hundred. there is no circularity: with `o/_types/types_gen/`
absent, the include path falls back to the binary's bundled
`/zip/.types`, the one sanctioned place a build reads the running
binary's bytes.

**payload generators run after compile**, so `embed_gen.tl` takes a
built closure like a test. its closure is the binary's scope.

**a person at a shell has no closure.** that is what `run` is for,
and it takes paths only:

```bash
cosmic --make run _perf/run.tl --out o/perf/current.json
```

it is `test`'s shape with a different contract: build the closure,
spawn the target with that closure as the resolution set, pass the
remaining argv and the exit code through. the run is what makes `o/`
fresh, so a benchmark cannot measure a stale tree. `run <name>` for a
binary refuses, naming `o/bin/<name>`: a built binary is already
executable, so that form buys a rebuild and nothing else. the callers
are `_perf/run.tl` and `_perf/gate.tl`, `_docs/publish.tl` from
`docs.yml`, and `_types/gentype.tl` after a pin bump.

## precedence against the standard library

if a project claims a namespace by defining `cosmic/init.tl`
outright, its own modules win over `/zip`'s in its own processes. if
it does not, `cosmic.*` comes from the running binary, and a project
cannot shadow a piece of the standard library.

the searcher does not enforce that. `tree_searcher` has no claims
check: layers 1 to 3 resolve any name the tree can spell. the property
holds one step earlier. `_make/validate.tl`'s `check_reserved` refuses
an unclaimed reserved import path before anything is spawned, so a
validated tree cannot contain a partial `cosmic.*` shadow for the
searcher to find. `cosmic/embed/floor.tl`'s `SUPERSEDABLE` is the same
rule for the artifact.

the boundary that leaves is reachable. `install_manifest` is public
API on `cosmic.searcher`, and a hand-written manifest fed to it, or
`--modules` pointed at one, shadows any namespace with no claims
check. that is fine for the engine, whose manifests only name a
validated project's closure, and a footgun for anyone else who finds
the API.

the sharp edge, stated: in this repo a test of `cosmic.fs` runs
against the tree's `cosmic/fs.lua`, not the binary's. that is what
you want, and it is also how a broken `cosmic.fs` breaks the thing
running the test. it is bounded by being per child: the engine keeps
running on its own payload, and only the spawned test sees the tree.

## the entry script stays lax

the searcher only sees required modules, so `cosmic foo.tl` compiles
`foo.tl` lax even inside a project. the alternative, strict inside a
project and lax outside, is a second rule keyed on "which project am
I in", the ambiguity `_make/root.tl` refuses to guess about, and it
would silently revoke the on-ramp for anyone running a script from a
directory that happens to be a project. `cosmic/searcher.tl`'s header
carries the same statement where the code lives.

## what it does to the fixpoint

`_make/converge.tl` answers which binary gates the tree. this chapter
answers which bytes a spawned child requires. they compose, and the
second shrinks the first's job: with the tree resolving first,
generation 1 already runs the tree's generators, the tree's tests and
the tree's modules. a build from a tree-built binary is one pass that
changes zero bytes.

what still needs a second generation is code running inside the
gating binary before it spawns anything: the dispatcher, the rules
file, the artifact packer and the `compile` step's own `cosmic.teal`,
all of which load from `/zip` because a recipe step is a fresh cosmic
with no manifest. change one of those and pass 1 builds with the old
one. that is why converge's cap is 2, and why it is not 1. converge's
trigger is unchanged: re-exec when the built artifact differs from
the running binary. its role is confirmation, not repair.

measuring this needs care. a clean build from the pin, hashed, then
built again and hashed, reports identical on any tree and proves
nothing: from a cold pin both sides converge by re-exec, and only the
pass count differs. pin exactly one pass with `COSMIC_MAKE_GEN=2` so
converge cannot supply a second.

## the gates

each claim above has a test. each reads a
`debug.getinfo(f, "S").source`, the only thing that answers "which
bytes ran" without trusting the thing under test to report on itself.

- `_make/resolution_test.tl`, run against fixture projects with their
  own roots so a rule that only holds for cosmic cannot pass: a
  fixture's test loads `o/greet/init.lua`, not `./greet/init.tl`;
  `run` resolves a computed require inside the project; `run` passes
  argv and the target's exit code through; a build spawned from a
  test resolves against its own root, never the outer one.
- `_make/generate_test.tl`: a generator's helper whose import path
  collides with one the binary embeds resolves to the tree. the
  collision is the whole test; a fixture module with a name cosmic
  does not ship can only come from the tree and proves nothing.
- `cosmic/searcher_tree_test.tl`: the layers one at a time, plus the
  edges an end-to-end test cannot reach: a manifest with no root, a
  missing one, a closure entry naming a file that is not there (loud,
  not a fall-through to `/zip`), a type error failing a require, and a
  warning not failing one.
- `_cli/build/modules_test.tl`: the manifest format, and the
  build-directory constant agreeing with the model's.
- `_make/artifact_test.tl`: a built artifact resolves from its own zip
  and ignores an ambient `LUA_PATH`.

a consequence visible in `.cosmic-coverage`: a file's total coverable
lines are measured against what the graph built, not against the
binary's embedded copy, so a total can move without its source
changing.

## open

- **where the fence draws the line for `run` and the generator
  pre-pass.** a test reads the whole project and the reasons are in
  `_cli/grants.tl`. `run` and the mini-graph inherit that today.
- **making the mini-graph's `/zip/.types` fallback loud.**
  it is the one sanctioned place a build reads the running binary's
  bytes, and a silent sanctioned exception is the shape every failure
  in this chapter took.
- **how deep a fenced build nests.** a `--make` build run from a test
  that is itself run by a nested `--make test`, four levels of
  `record` each intersecting its parent's Landlock policy, fails in CI
  with `No rule to make target` and passes standalone. three levels is
  what `_make/fixtures_test.tl` and `_make/build_test.tl` do, and they
  pass, so the limit sits between. the non-inheritance gate asserts
  the mechanism at two levels: a grandchild inheriting the parent's
  whole environment still resolves from source. the depth ceiling is
  a fence question and wants its own change.
