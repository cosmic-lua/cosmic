# How `--make` is designed

the design of cosmic's build system, one chapter per file, for a
contributor who changes `_make/`, `_cli/build/` or the conventions a
project is read by.

`--make` is cosmic's build system. it builds a project by convention:
the tree is the project. there is no spec file and no rules file. one
binary with no host toolchain does the whole thing.

| chapter | what it settles |
|---|---|
| [choices.md](choices.md) | the decision table: every question and its answer |
| [model.md](model.md) | the project model: markers, units, generators, pins and `exec` |
| [artifact.md](artifact.md) | the artifact: layout, the strip floor, reproducibility |
| [engine.md](engine.md) | constant rules and generated facts, cosmic as `SHELL`, the fence, staleness |
| [resolution.md](resolution.md) | which bytes answer `require()` in a spawned child |
| [testing.md](testing.md) | what a test may read and write |
| [verbs.md](verbs.md) | the command surface: graph verbs and policy verbs |
| [examples.md](examples.md) | what a project written to these conventions looks like |
| [payload.md](payload.md) | what cosmic's own artifact carries, and what it weighs |

## the shape

1. conventions. a project is a directory tree. filenames and directory
   positions declare intent.
2. a constant rules file plus generated facts. `embed/cosmic.mk` ships
   inside the binary at `/zip/cosmic.mk`, byte-identical for every
   project. `o/project.mk` is generated and holds only variable
   assignments. no rule is ever generated.
3. cosmic as `SHELL`. make runs `cosmic -c '<line>'` for every recipe
   line. a line is whitespace-split argv. its first word is a cosmic
   verb, or `exec`, which resolves only to pinned bytes.
4. the pinned make, embedded. cosmic extracts it to `o/make` on first
   use. one binary, offline, no host toolchain.

```bash
cosmic --make build   # strict check, compile, stage, embed: o/bin/<name>
cosmic --make test    # tests, fenced, against the staged tree
cosmic --make fetch   # the only verb that touches the network
cosmic --make ci      # fmt, check, example, lint, coverage
```

two sentences carry most of the design:

- **inputs = grants = your staged subtree.** what a generator may read,
  what a test may read and what the sandbox permits are one set. the
  corollary: put a file where its inputs are.
- **a build runs only bytes you pinned, and runs your code without a
  socket.** pins are data. `fetch` is the only networked verb. `exec`
  resolves only to pinned artifacts. so the external surface of a build
  is enumerable from committed files.

the project-wide promises these serve are in
[goals.md](../../../goals.md); the tradeoffs that are not `--make`'s
own are recorded in [decisions](../../../decisions/).
