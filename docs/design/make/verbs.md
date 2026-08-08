# Verbs

The command surface: graph verbs that build something, and policy verbs
that orchestrate them.

**Graph verbs:**

```
build [binaries…] compile → generate → stage → embed → o/bin/<name> [now]
test  [paths…]  build the stage, run *_test.tl fenced against it     [now]
check [paths…]  strict type-check only                               [now]
fmt   [paths…]  --check fmt (--fix to rewrite)                    [now]
fetch [paths…]  resolve *_pin.tl — the only verb with network        [now]
clean           remove o/                                            [now]
run   <path>    build, then run that source against the tree         [now]
benchmark [paths…]  run every *_benchmark.tl against the stage       [now]
example [paths…] run Example_* against the staged tree               [now]
lint  [paths…]  style gate: file length, cast reasons, test order  [now]
```

`run` takes **paths, never binary names**: a built `o/bin/<name>` is
already executable, so the binary form bought a rebuild and nothing
else, while the source form is what every caller in this repo needs
(`_perf`, `_docs`, `_types`). `run <name>` refuses, naming
`o/bin/<name>`. See [resolution.md](resolution.md), which is also where
"against the tree" is defined.

**Selection names targets of the verb's own kind, and never changes
what a target means** — `test` states it as "selection changes which
tests run, never what gets staged". `build`'s targets are BINARIES, so
`build cmd/foo` (or `build foo`) builds foo: the full pipeline, staging
what a full build would, and never a narrowed compile. A source path is
refused, pointing at `check`, whose targets *are* sources.

**Every verb answers about paths, and answers first.** `V S` is the
`S`-restriction of a full `V`; a verb with no such restriction —
`clean` removes the build directory, `ci` is a verdict over the whole
gate — refuses a path and names why, rather than accepting one and
ignoring it. That third behaviour is the one that teaches a spelling
which does something else. `_make/law.tl` is where this lives, and it
runs against the scanned model BEFORE the gate converges, so a typo
costs a walk instead of a rebuild.

**Policy verbs** — orchestration over the graph, never graph rules.

```
ci              fmt → check → example → lint → coverage               [now]
coverage        tests with line coverage + ratchet                    [now]
docs  [paths…]  render the model's file set to o/docs                 [now]
enforce         sandbox-enforced lane                             [planned]
reproducible    double-build + compare                            [planned]
offline         no-network lane, asserted against the pins        [planned]
```

`example` and `lint` are verbs in their own right (above), so
`ci` is a list of verb names rather than a lane reimplementing two of
its five stages. `example` is `test`'s sibling — same staging, same
fence, `Example_*` instead of the test contract — which is what the
model already says everywhere else. `lint` stays out of `check`: its
file set is the whole tree, not the compiled closure. There is no
separate `test` stage in `ci`: `coverage` runs the same test recipe
with collection on, and its ratchet summary passes or fails a failing
test the same way a plain run would, so a second, uninstrumented pass
bought the gate nothing but wall-clock (measured: 157s summed for the
plain lane against 351s for the instrumented one). `--make test` alone
is unchanged — it stays the fast, uninstrumented developer loop.

`ci` is a fixed order with **each stage gated by whether the project has
material for it** — no tests, no coverage stage; no committed coverage
baseline, no ratchet. Zero configuration, and a fresh project doesn't
fail on a stage that had nothing to do. (A baseline is *input* data, so
it stays committed; only generated things are banned from the tree.)

Every verb ends in a machine-readable verdict line and an exit code.

## The lanes converge on the verbs

Each pr.yml lane carries real logic as YAML-embedded bash, which is
exactly the orchestration the design assigns to policy verbs. Logic in
YAML is unrunnable locally, unversioned by the verbs' tests, and
per-forge. The convergence target is that every job is checkout + setup
+ **one verb**:

| YAML today | destination |
|---|---|
| the netns bring-up around the gate | the `offline` verb — the bring-up is already cosmic code |
| build, copy, clean, rebuild elsewhere, `cmp` | the `reproducible` verb |
| the enforce lane plus its canary | the `enforce` verb, printing its own evidence |
| `--make fetch` twice, asserting the second fetches nothing | `fetch`'s own idempotence check |
| "dump failing test output" (find + cat over `.got`/`.out`/`.err`) | **the reporter.** A failing gate should print the failing tests' captured output itself; the dump step exists because the summary does not, and every other consumer of the gate — a laptop, a downstream repo — lacks it too |

Do the reporter piece first: it is verb-independent, it shrinks every
lane, and it improves the local experience today.

