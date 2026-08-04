# Build System

## Quick Reference

```bash
bin/cosmic --make fetch     # resolve *_pin.tl — the only verb with a network
bin/cosmic --make build     # o/bin/cosmic and o/bin/cosmic-debug
bin/cosmic --make ci        # fmt, check, example, lint, coverage
bin/cosmic --make clean     # remove o/
bin/cosmic --make help      # every verb, and which are still planned
```

**Gate under the binary you built:**

```bash
bin/cosmic --make build && o/bin/cosmic --make ci
```

`bin/cosmic` execs the *pinned* release, and modules resolve from that
artifact before the tree — so `bin/cosmic --make ci` checks the pin's
code, not yours. It will run the released formatter over a formatter fix
and pass. CI builds first and gates with the result.

## How It Works

`cosmic --make` builds a project **by convention**. There is no build
spec: the tree is the project, and a file's position and name declare
what it is.

| marker | declares |
|---|---|
| `<dir>/*.tl`, `<dir>/*.lua` | a package: compile, check, format |
| `_<dir>/` | internal — importable only from within its container |
| `*_test.tl`, `*_example.tl` | a test / example target |
| `testdata/` | fixtures; never embedded |
| `*.d.tl` | type-only; include path, never embedded |
| `cmd/<name>/main.tl` | a binary → `o/bin/<name>` |
| `<dir>/*_pin.tl` | a pinned external asset |
| `<dir>/*_gen.tl` | a generation unit: runs BEFORE the graph, owns `o/<its path minus .tl>/` |
| `cmd/<name>/embed_gen.tl` | that binary's payload generator: runs after |
| `embed/**` | payload, embedded at its path inside `embed/` |
| everything else | an asset: part of the project, not of its artifacts |

**Import path = path relative to the root**, `/`→`.`, extension dropped.
The repo root is the module root, and so is the zip root, so that holds
inside the artifact too.

Nothing lists any of this. A directory added to the tree is built,
checked, tested and documented without anyone registering it.

### Constant rules, generated facts

`embed/cosmic.mk` is a committed file, shipped inside the binary at
`/zip/cosmic.mk`, and byte-identical for every project. **No rule is ever
generated.** `o/project.mk` holds only variable assignments —
`srcdeps_<stem>`, each source's transitive import closure — which the
compile rule takes as prerequisites, so a module whose contract changed
recompiles its importers. It is output; never commit it.

### Cosmic as `SHELL`

Make runs `cosmic -c '<line>'` for every recipe line. A line is **argv,
not shell**: whitespace-split, `argv[0]` a verb from a closed vocabulary
(`_cli/build/`), and shell metacharacters are refused rather than
interpreted. Cosmic derives its sandbox grants from the line's own shape
— `copy <src> <dst>` reads the first and writes the second — and
self-restricts before doing the work. A rule cannot over-declare its way
out of the fence, because a rule declares nothing.

Compiles are **always** strict (type check, then generate from that same
checked AST), which is what makes output independent of parallel build
order. There is no flag to select it.

### Versioned dependencies (3p/)

A `*_pin.tl` is Teal **data** — a `return { … }` of literals, read by
`cosmic.literal` and never executed. It names a url and the sha256 of the
bytes it must produce; `fetch` verifies before unpacking, because an
archive is a program for a decompressor and running one on unverified
bytes is what pinning exists to prevent.

`fetch` unpacks a pin **beside the pin**, so `3p/cosmos/cosmos_pin.tl`
lands in `o/3p/cosmos/` and `3p/tl/tl_pin.tl` in `o/3p/tl/`.

### Artifacts

A unit's output directory holds `embed/` — what the artifact carries —
next to `base`, what it carries it on. A `base-<variant>` written beside
`base` ships the **same staged payload** on that runtime as
`o/bin/<name>-<variant>`; staging happens once, so the two cannot drift.
That is how one build produces both release binaries.

**Shipping is opt-in**: an artifact carries its modules plus `embed/**`
and nothing else. The base is stripped to a positive floor — compiled
`cosmic/**`, TLS roots, zoneinfo, `.args` — a keep-list rather than a
strip-list, so a base that grows a directory cannot start shipping it
silently.

Zip entries carry a fixed mtime rather than the staging file's, so two
builds of one tree are byte-identical. CI proves it by building twice
into different tree *paths* and comparing.

## CI

Three lanes in `.github/workflows/pr.yml`:

- **`ci`** — fetch with a network, then build and run the whole gate
  inside a loopback-only network namespace, so a stray download fails
  loudly.
- **`build`** — everything needing a real network or a real kernel:
  double-build reproducibility, `--make fetch` against the real pins, and
  the sandbox-enforcement lane.
- **`smoke`** — the built binary on real macOS and Windows runners.

## Selection

Every graph verb takes paths, and selection names targets **of that
verb's own kind**:

```bash
o/bin/cosmic --make test cosmic/string_test.tl   # one test
o/bin/cosmic --make build cmd/cosmic             # one binary
```

`build`'s targets are binaries, so a source path is refused — pointing at
`check`, whose targets *are* sources. Selection never changes what a
target means: `build cmd/foo` runs the full pipeline, staging exactly
what a full build stages.

## Bootstrap

Building cosmic needs a cosmic. `bin/cosmic` is the trust root: POSIX sh
that obtains **one** pinned artifact named in `bin/cosmic.pin`, verifies
its sha256, assimilates it to a native ELF (sandboxed rules cannot grant
the APE loader's extraction), and execs it. Everything after runs under
that pin — cosmic extracts its own build engine from its own zip.

    kernel → bin/cosmic → one pin → everything else

The pin is bumped by hand. A release is built in two generations — the
pinned cosmic builds one from the tree, and *that* one builds what ships
— so a release is produced by the code it contains rather than by
whatever the pin happens to be.

The trust root's shape, and the settled decision that make stays the
graph executor, are recorded in [decisions/](decisions/) (D13, D14).
