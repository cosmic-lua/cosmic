# Try a `--make` change by hand

steps to exercise a change to `_make/` or `_cli/build/` on a small
project before the full gate, for a contributor editing the build
engine. `../../reference/make.md` has the verbs and the project model;
[../explanation/make/README.md](../explanation/make/README.md) has the
design.

## 1. pick a fixture

`_make/testdata/` holds one hello-world-sized project per promise. each
has its own root, so the repo's model never sees it.

| fixture | exercises |
|---|---|
| `hello` | the smallest project: one entry, `cmd/hello/main.tl`, and an artifact that runs |
| `pkg` | import path is position: `greet/init.tl` is `require("greet")`, `greet/loud.tl` is `require("greet.loud")` |
| `multi` | two binaries from one tree; each `cmd/<name>/` ships the root packages plus its own subtree |
| `luaonly` | `.lua` sources are first-class; no `.tl` anywhere |
| `assets` | payload under `embed/` ships; `README.md` and `testdata/` do not |
| `runner` | a runner-mode `*_test.tl` checked from a tree that never built |

## 2. copy it out and build it

work on a copy. `--make` writes `o/` into the project root, and the
fixture directories are committed.

```bash
cp -r _make/testdata/hello /tmp/h
cd /tmp/h
$OLDPWD/o/bin/cosmic --make build
./o/bin/hello
# hello from hello
```

`COSMIC_MAKE_ROOT=/tmp/h` names the root instead of the working
directory, for a run from the repo root.

## 3. change the engine and go again

1. edit under `_make/` or `_cli/build/`.
2. rebuild cosmic at the repo root:

   ```bash
   bin/cosmic --make build
   ```

3. rerun the verb in the copy. run `check`, `test` and `ci` there too.
   the copy is an ordinary project, so no convergence happens and the
   binary you name is the binary that runs.
4. read `o/project.mk` in the copy for the generated facts: one
   `srcdeps_<stem>` line per source, its transitive import closure.

three variables help when a run fails for a reason the message does
not show:

| variable | effect |
|---|---|
| `COSMIC_FENCE=0` | opts out of the derived sandbox, to tell a grant bug from a logic bug |
| `COSMIC_JOBS=1` | one job at a time, so recipe output stays in order |
| `COSMIC_INSTRUMENTATION=1` | timing spans on stderr, one `key=value` line each |

## 4. run the fixture test

`_make/fixtures_test.tl` copies every fixture to a scratch directory
and checks, builds, tests and runs it through the spawned binary:

```bash
o/bin/cosmic --make test _make/fixtures_test.tl
```

`_make/*_test.tl` covers each rule in isolation. `o/bin/cosmic --make
test _make` runs them all.

## 5. run the fixpoint test

run this when the change touches the artifact pipeline:
`_make/artifact.tl`, `cmd/cosmic/embed_gen.tl`, or base selection.

```bash
COSMIC_FIXPOINT=1 bin/cosmic --make test _make/fixpoint_test.tl
```

it builds cosmic twice more and compares generation 2 with generation
3 byte for byte, which takes about 80 seconds. generation 2 proves the
product works; generation 3 proves the process converges. CI's `build`
lane asserts the same fixpoint on every push, so the gate does not pay
for it on every `--make test`.

## 6. run the whole gate

```bash
bin/cosmic --make build && o/bin/cosmic --make ci
```
