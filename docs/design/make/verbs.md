# Verbs

The command surface: graph verbs that build something, and policy verbs
that orchestrate them.

**Graph verbs:**

```
build [binaries…] compile → generate → stage → embed → o/bin/<name> [now]
test  [paths…]  build the stage, run *_test.tl fenced against it     [now]
check [paths…]  strict type-check only                               [now]
fmt   [paths…]  --check format (--fix to rewrite)                    [now]
fetch [paths…]  resolve *_pin.tl — the only verb with network        [now]
clean           remove o/                                            [now]
run   [binary]  build, then exec the artifact with remaining argv    [planned]
benchmark [paths…]  run every *_benchmark.tl against the stage
regen [paths…]  run generation units                                 [planned]
example [paths…] run Example_* against the staged tree               [planned]
lint  [paths…]  style gate: file length, column width, cast ratchet  [planned]
```

**Selection names targets of the verb's own kind, and never changes
what a target means** — `test` states it as "selection changes which
tests run, never what gets staged". `build`'s targets are BINARIES, so
`build cmd/foo` (or `build foo`) builds foo: the full pipeline, staging
what a full build would, and never a narrowed compile. A source path is
refused, pointing at `check`, whose targets *are* sources.

**Policy verbs** — orchestration over the graph, never graph rules.
Planned; these lanes are workflow steps today:

```
ci              format → check → test → example → lint → coverage
coverage        tests with line coverage + ratchet
enforce         sandbox-enforced lane
reproducible    double-build + compare
offline         no-network lane, asserted against the pins
```

`example` and `lint` are verbs in their own right (planned, above), so
`ci` is a list of verb names rather than a lane reimplementing two of
its six stages. `example` is `test`'s sibling — same staging, same
fence, `Example_*` instead of the test contract — which is what the
model already says everywhere else. `lint` stays out of `check`: its
file set is the whole tree, not the compiled closure.

`ci` is a fixed order with **each stage gated by whether the project has
material for it** — no tests, no test stage; no committed coverage
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

