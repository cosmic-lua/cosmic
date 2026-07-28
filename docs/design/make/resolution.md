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

> **In a project, the project's own build closure answers first.**

Precedence for a child the engine spawns:

1. the **build closure** — the exact files the graph produced for this
   target
2. the running binary's payload (`/zip/**`)
3. cosmopolitan's own (`/zip/.lua/**`)
4. source, lax-compiled by `cosmic.searcher` — the gradual-typing
   on-ramp, unchanged

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

An explicit map rather than a path prefix, for four reasons that are
all consequences of the design already in place:

- **exact** — a prefix over `o/` also offers `o/x.tl.test.got`,
  `o/.coverage/**` and every other build dropping in the mirror. A map
  offers what the graph built and nothing else.
- **already fresh** — make made those exact files before the recipe
  ran. There is no window where a stale `o/` wins, because the
  prerequisites are the map.
- **already fenced** — the paths *are* the read grants, so resolution
  cannot reach what the fence denies. Two mechanisms that cannot
  disagree, because they are one list.
- **it degrades to today** — a module outside the closure falls through
  to `/zip`, so a script run by hand, with no closure, behaves exactly
  as it does now.

## Three cases the closure does not cover by itself

**Source generators run before the graph.** A `*_gen.tl` writes build
*inputs*, so it runs before anything is compiled and has no built
closure to resolve through. Its imports are still computable —
`_make/imports.tl` reads them without compiling — so it can be handed a
**source** closure and let the searcher compile it lax, ahead of
`/zip`. That closes the split-brain today, with the same list computed
the same way, and `_make/generate.tl` already spawns these itself so
there is no recipe to change.

The end state is stricter: compile a generator's closure first, as a
mini-graph before the graph, so generation is strict like everything
else. That is a phase-ordering change and should be its own step.

**Payload generators run after compile**, so `embed_gen.tl` takes a
built closure like a test. Its closure is the binary's scope, which the
model already defines.

**A human at a shell has no closure at all.** This is what `run` is
for, already listed as planned in [verbs.md](verbs.md):

```
cosmic --make run <path> [args…]    # build, then run it against the built tree
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

Open: `run`'s argument grammar. `build` already disambiguates a binary
name from a path; `run cosmic` (exec `o/bin/cosmic`) and `run
_perf/run.tl` (run this source against the tree) can use the same rule,
or `run` can take paths only and leave `o/bin/<name>` to be executed
directly. The verb table's current entry means the first.

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
the first's job: with the closure resolving first, generation 1 already
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
- `_make/artifact_test.tl`'s existing shape, unchanged and still
  passing: a built artifact resolves from its own zip and ignores an
  ambient `LUA_PATH`
- the second compile disappears — a test run stops writing to the
  script cache

## Open questions

1. **`run`'s grammar** — binary name, source path, or both (above).
2. **Source generators** — source closure now, or compile-first
   mini-graph? Recommendation: the first now, the second as its own
   phase.
3. **Does the map replace `LUA_PATH` entirely?** Recommendation: yes
   for the engine. `LUA_PATH` stays defeated by `WRAP_MAIN`, which is
   correct for artifact identity — but then `cmd/cosmic/main.tl`'s
   "BEHIND anything `LUA_PATH` set" comment and the `TREE_LUA_PATH`
   branch in `_cli/build/steps.tl` are dead intent and should go with
   this change.
4. **Should an unbuilt `.tl` in the tree beat an embedded `.lua`?**
   Recommendation: no. The closure is the declaration; anything outside
   it falls through to `/zip`, which is what keeps "the artifact
   answers for itself" true and keeps the behavior of a hand-run script
   unchanged.
