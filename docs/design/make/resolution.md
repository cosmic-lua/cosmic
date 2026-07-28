# Module resolution

Which bytes answer `require("x.y")` in a process the build spawns.

The [model](model.md) says *import path = path relative to root*, and
the graph compiles every source to `o/<path>.lua`. Neither sentence is
about run time, and nothing else in the design is either — so what a
spawned child actually loads is whatever `package.path` happens to say.
Measured, it is never the thing the build just produced.

## What happens today

`package.path` inside any cosmic artifact, in order:

```
/zip/?.lua  /zip/?/init.lua          the generated entry wrapper prepends this
/zip/?.lua  /zip/?/init.lua          cmd/cosmic/main.tl inserts it again
/zip/.lua/?.lua  /zip/.lua/?/init.lua    cosmopolitan's own
./?.lua  ./?/init.lua                cwd
```

then `cosmic.searcher`, appended last, which resolves `./x/y.tl` and
compiles it **lax**. So a require resolves, in order, to:

1. the **running binary's** copy of the module, if it embeds one
2. a committed `.lua` in the tree
3. the tree's `.tl` **source**, lax-compiled

`o/` appears nowhere. The build's output is unreachable by name, and
which of the three you get depends on whether the binary you happen to
be running ships a module with that import path.

## Three failures, each reproduced

**A generator silently produces stale output.** `_types/types_gen.tl`
is a generation unit and is not embedded, so it loads from the tree —
but `_types/gentype_render.tl` *is* embedded, so it loads from `/zip`.
One generator, two generations of code. Editing the renderer and
building once:

```
$ sed -i '335s|GENERATED from|GENERATED-MARKER-XYZ from|' \
    _types/gentype_render.tl
$ o/bin/cosmic --make build && head -2 o/_types/types_gen/cosmo.d.tl
-- GENERATED from cosmopolitan's definitions.lua by _types/gentype.tl.   # stale
$ o/bin/cosmic --make build && head -2 o/_types/types_gen/cosmo.d.tl
-- GENERATED-MARKER-XYZ from cosmopolitan's definitions.lua by …         # second build
```

Two full builds for a one-line change to a generator's helper, and the
first one reports `build: PASS`. This is the fixpoint
([converge](../../../_make/converge.tl)) and the release loop's second
`--make build` earning their keep — but they are covering for
resolution, not for anything intrinsic.

**A test never runs what the graph compiled.** The `deps_*` machinery
computes each test's transitive closure as *built* paths, makes them
prerequisites, and passes them as `--deps` so the fence can grant them.
The test then loads something else. In a user project
(`_make/testdata/pkg`, with a test that prints
`debug.getinfo(greet.hi, "S").source`):

```
LOADED FROM: @./greet/init.tl
```

not `o/greet/init.lua`, which was built, listed and granted. In this
repo, the same probe under `--make test`:

```
_make.project <- @/zip/_make/project.lua
cosmic.fs     <- @/zip/cosmic/fs/path.lua
```

So cosmic's tests test the **binary's** modules and a user's tests test
**lax-compiled source**; neither tests the strict-compiled bytes that
ship. `deps_*` schedules and fences a set of files nothing opens.

The cost has a second half: a user project compiles every module twice
per test run — once strict into `o/`, once lax through the searcher —
and the lax half is not cached across steps, because the cache
directory derives from `TMP` and `record` points `TMP` at a fresh
per-step scratch (`<out>.tmp.d`).

**The perf harness measures the binary, not the tree.** `_perf/harness`
and every `_perf/bench/*` are embedded, so:

```
$ o/bin/cosmic _perf/run.tl … _perf.bench.json_bench     # tree entry
$ o/bin/cosmic o/_perf/run.lua …                         # OPTIMIZE.md's form
_perf.harness <- @/zip/_perf/harness.lua                 # both
```

Edit `_perf/harness.tl` or a scenario, re-run either command, and
nothing changes. `o/_perf/harness.lua` is sitting right there, built
and never loaded. `_perf/OPTIMIZE.md` already warns that a benchmark
"cannot tell you it read the wrong subject"; this is that trap one
level down, below where naming `$BIN` can reach.

**And there is no escape hatch.** The old Makefile had one —
`tree_lua_path`, an opt-in `LUA_PATH` per lane — and
`cmd/cosmic/main.tl` still documents inserting the zip root "BEHIND
anything `LUA_PATH` set … prepending outright would shadow an in-tree
build with the binary's own copy". The generated entry wrapper
(`cosmic/embed/init.tl`, `WRAP_MAIN`) prepends it unconditionally, one
frame earlier, so `LUA_PATH` cannot reach ahead of `/zip` at all.
`TREE_LUA_PATH` survives in `_cli/build/steps.tl` with nothing setting
it.

## The rule

> **In a project, the tree answers. Outside one, the binary does.**

Precedence for a child the engine spawns:

1. the **build closure** — the exact files the graph produced for this
   target
2. the rest of the **tree**, compiled strictly by `cosmic.searcher`
3. the running binary's payload (`/zip/**`)
4. cosmopolitan's own (`/zip/.lua/**`)

Layers 1 and 2 are the same answer at different costs: the closure is
what the graph already built, so it is a cache and a freshness
guarantee, not a separate semantics. Deleting `o/` changes how long a
require takes and not what it returns. That is what makes the rule one
sentence instead of a table.

**Layer 2 is strict**, and that is what earns it its position. A lax
compile ahead of the binary's checked bytes would mean position
deciding which of two compile modes you got; strict makes the two
layers agree by construction, so "the tree wins" costs nothing but time.
It also puts generators, tests, scripts and the artifact on one compile
configuration, which `cosmic.teal`'s own doc comment already names as a
goal.

An artifact running as *itself* keeps today's order exactly. That is
not a compromise; it is the other half of the same rule. A built binary
must answer from its own zip no matter what the environment says —
`_make/artifact_test.tl` names its child's environment rather than
inheriting it precisely so an artifact test cannot be answered by the
checkout that built it. Which is why the mechanism below is **not**
`LUA_PATH`.

## The closure is already in the line

`--deps` already carries the transitive import closure, as built paths,
on every test, example, benchmark and coverage recipe. `_make/deps.tl`
computes it, and its own doc comment says why it is one function: "Two
things want this answer" — the graph, for scheduling, and the fence,
for grants.

Make it three. Cosmic builds `import path -> file` from those same
paths and installs it as a searcher ahead of everything else. Nothing
new is declared, nothing is configured, and the argument positions stay
the declaration.

An explicit map rather than a path prefix, for three reasons that are
all consequences of the design already in place:

- **exact** — a prefix over `o/` also offers `o/x.tl.test.got`,
  `o/.coverage/**` and every other build dropping in the mirror. A map
  offers what the graph built and nothing else.
- **already fresh** — make made those exact files before the recipe
  ran. There is no window where a stale `o/` wins, because the
  prerequisites are the map.
- **already fenced** — the paths *are* the read grants, so resolution
  cannot reach what the fence denies.

**It travels in argv and does not inherit.** Ten `_make/*_test.tl`
files spawn a cosmic against a *different* project root under `/tmp`.
Carried in the environment, this repo's `o/` would answer `cosmic.*`
and `_make.*` while those children built unrelated projects — the
ambient-export bug class the old Makefile fought (#720, #666, #608),
which is why `tree_lua_path` was opt-in per lane and never exported.
`--deps` is per-invocation by construction, so there is nothing to
scrub. A child that spawns a child and wants the same resolution passes
it on deliberately.

## What layer 2 costs, and what the fence has to say

Layer 2 fires for imports no closure names, which is exactly the class
`_make/deps.tl` calls out: "A computed require is invisible there, and
the consequence is a denied read rather than only a missing rule."
`_perf/run.tl:163` is that case in this repo — `pcall(require, name)`
with `name` off argv, which is how every `_perf/bench/*_bench.tl`
scenario loads. Under layer 3 alone the flagship case comes out
half-fixed: the harness resolves from the tree and the scenario still
comes from `/zip`, silently.

So the fence has to grant reads it did not derive. For a **test** it
already does — `_cli/grants.tl` gives `record` `ro = "."`, the whole
project, with the reasons written down there. For `run` and for the
generator pre-pass below, the same call has to be made explicitly
rather than inherited by accident.

## Three cases the closure does not cover by itself

**Source generators run before the graph.** A `*_gen.tl` writes build
*inputs*, so it runs before anything is compiled and has no built
closure to resolve through. The answer is a **mini-graph**: compile each
generator's closure strictly into `o/` first, then run the generator
against those built paths. Uniform with everything else — nothing the
build runs is unchecked at the moment it runs — and `_make/generate.tl`
already spawns these itself, so there is no recipe to change.

Two measurements say the cost is affordable and the ordering works:

- `srcdeps__types/types_gen` is **20 files of 375**. A pre-pass over
  generator closures is a fraction of the tree, not the graph again.
- **no circularity.** Removing `o/_types/types_gen/` and strict-compiling
  `_types/gentype.tl` succeeds: the include path falls back to the
  binary's bundled `/zip/.types`. So a generator that produces the
  type declarations can be compiled without them, on a cold tree.

That fallback is itself an instance of the theme this chapter is about —
a cold build bootstraps its types through the running binary's copy —
and it is the one place where that is load-bearing rather than
accidental. It should be stated in `model.md`'s generator section rather
than left to be discovered.

**Payload generators run after compile**, so `embed_gen.tl` takes a
built closure like a test. Its closure is the binary's scope, which the
model already defines.

**A human at a shell has no closure at all.** This is what `run` is for
— **paths only**:

```
cosmic --make run <path> [args…]    # build, then run this source against the tree
```

`test`'s shape with a different contract: build the closure, spawn with
that closure as the resolution set. It is what `_perf` wants —

```
cosmic --make run _perf/run.tl --out o/perf/current.json $BENCH
```

— and it retires the "measures whatever `o/` happens to hold" warning
from `_perf/OPTIMIZE.md` by construction: the run is what makes `o/`
fresh. `_docs/publish.tl`, invoked from `docs.yml` as a bare tree
script, is the other caller: it imports no siblings so nothing is stale
today, but it is correct only for as long as `bin/cosmic` happens to
resolve to a current `o/bin/cosmic`.

**This amends [verbs.md](verbs.md)**, whose entry reads `run [binary]
build, then exec the artifact with remaining argv`. The binary form has
no caller: `o/bin/<name>` is already executable, so it buys a rebuild
and two saved tokens, while the source form is what all six broken
commands in this repo need. `run <name>` becomes a refusal that names
`o/bin/<name>`; the `go run ./cmd/foo` ergonomic waits for a project
that asks for it, under a word chosen then.

## Precedence against the standard library

If a project **claims** a namespace — `validate.claims(proj)`, the test
the artifact staging and `converge` already share — its own modules win
over `/zip`'s in its own processes. If it does not claim it, `cosmic.*`
always comes from the running binary and a project cannot shadow a
*piece* of the standard library.

That is `cosmic/embed/floor.tl`'s `SUPERSEDABLE` rule, applied at run
time instead of at pack time. One rule, already written down, in a
second place.

Stated plainly, because it is the sharp edge: in this repo that makes a
test of `cosmic.fs` run against the tree's `cosmic/fs.lua` rather than
the binary's — which is what you want, and is also how a broken
`cosmic.fs` breaks the thing running the test. It is bounded by being
per-child: the engine keeps running on its own payload, and only the
spawned test sees the tree.

## What it does to the fixpoint

`converge` answers *which binary gates the tree*. This answers *which
bytes a spawned child requires*. They compose, and the second shrinks
the first's job: with the tree resolving first, generation 1 already
runs the tree's generators, the tree's tests, and the tree's modules.

What still needs a second generation is code running *inside* the
gating binary before it spawns anything — the dispatcher, the rules
file, the artifact packer. So **converge stays**, and the release
loop's second `--make build` stays with it. The expectation is that
generation 2 stops changing bytes in the common case; that is a
measurement to take after this lands, not a claim to make before.

## How we would know it works

- a fixture test asserting a test loads `o/**.lua`, not `./**.tl` —
  the `debug.getinfo(f, "S").source` probe used throughout above
- the split-brain ratchet: edit a generator's helper, build **once**,
  assert the output reflects it
- the computed-require case: edit `_perf/harness.tl` *and* a
  `_perf/bench/*_bench.tl`, `--make run` once, assert both took effect —
  the second is what layer 2 exists for and no closure names it
- `_make/artifact_test.tl`'s existing shape, unchanged and still
  passing: a built artifact resolves from its own zip and ignores an
  ambient `LUA_PATH`
- an inheritance ratchet: a fixture build spawned from a test resolves
  against *its own* root, never this one
- the second compile disappears — a test run stops writing to the
  script cache

## Settled

1. **`run` takes paths only.** The binary form is dropped; `verbs.md` is
   amended.
2. **Source generators get a compile-first mini-graph**, straight away —
   not a lax source closure.
3. **The closure travels in argv and does not inherit.** `LUA_PATH` is
   not the channel and is not restored; `WRAP_MAIN`'s prepend is correct
   for artifact identity and stays. `cmd/cosmic/main.tl`'s "BEHIND
   anything `LUA_PATH` set" comment and the `TREE_LUA_PATH` branch in
   `_cli/build/steps.tl` are dead intent and go with this change.
4. **The tree outranks the binary, closure or not**, and in-tree
   compilation is **strict** — which is what makes 4 safe, and what
   makes the closure a cache rather than a semantics.

## Open

- **Do warnings fail a require?** Strict mode in `cosmic.teal` means
  werror ("warnings fail too, matching check's default"), so a shadowed
  local in a module outside the closure would fail the `require` that
  loads it rather than the gate that checks it. Type errors should fail
  it; warnings are the question, and the honest answers are "yes, one
  standard" or "no, `--check types` stays the only werror gate."
- **Does strict apply to the entry script itself?** The lax on-ramp for
  a hand-run `cosmic foo.tl` is a deliberate promise (`cosmic.teal`'s
  own doc comment, and the skill's gradual-typing story). Strict *inside
  a project* and lax for a file run from anywhere else is defensible but
  it is a second rule, and "which project am I in" is exactly the
  ambiguity `_make/root.tl` refuses to guess about.
- **Where the fence draws the line for `run` and the generator
  pre-pass.** A test already reads `.` and the reasons are written down
  in `_cli/grants.tl`; these two need the same call made deliberately
  rather than arrived at.
- **Whether the mini-graph's `/zip/.types` fallback should be loud.** It
  is the one sanctioned place a build reads the running binary's bytes
  instead of the tree's, and a silent sanctioned exception is how the
  rest of this chapter's failures got in.
