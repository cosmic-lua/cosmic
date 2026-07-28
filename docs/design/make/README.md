# Design — `cosmic --make`

`--make` is **cosmic's build system**, not a wrapper around `--embed`,
and this repo builds with it. It builds a project **by convention**: the
tree is the project — no spec file, no `rules.tl`, no `cook.mk` — and
one binary with no host toolchain does the whole thing.

This design is one chapter per file, the way `_perf/optimize/` is split,
so no chapter has to fight the length cap:

| chapter | what it settles |
|---|---|
| [choices.md](choices.md) | the decision table — every question and the answer it took |
| [model.md](model.md) | the project model: markers, units, generators, pins and `exec` |
| [artifact.md](artifact.md) | the artifact: layout, the strip floor, reproducibility |
| [engine.md](engine.md) | constant rules and generated facts, cosmic as `SHELL`, staleness |
| [resolution.md](resolution.md) | which bytes answer `require()` in a spawned child |
| [testing.md](testing.md) | what a test may read and write |
| [verbs.md](verbs.md) | the command surface, graph verbs and policy verbs |
| [examples.md](examples.md) | what a project written to these conventions looks like |
| [payload.md](payload.md) | what cosmic's own artifact carries, and what it weighs |
| [plan.md](plan.md) | delivery: provisioning, gates, open items |
| [phasing.md](phasing.md) | the order the work lands in, and why that order |
| [log/](log/) | what each landed slice *taught*; the reasoning behind anything that looks arbitrary |

## What this replaced

`--make [dir] [target]` scanned for `*.tl`, classified by suffix,
emitted a Makefile and ran make on it. Three things were wrong with it,
and they are what this design addresses: it **needed a host make**, it
**produced build files, not builds**, and its **project model was a
flat scan** — no packages, no entry point, no artifact, no notion of
what ships. Dropped whole in 2a; the fuller account is in
[log/phase1-2.md](log/phase1-2.md).

## The shape

1. **conventions** — a project is a directory tree. filenames and
   directory positions declare intent. no spec file, no `rules.tl`, no
   `cook.mk`.
2. **a constant rules file plus generated facts** — `o/cosmic.mk` ships
   inside the binary, byte-identical for every project. `o/project.mk`
   is generated and holds *only variable assignments*. no rule is ever
   generated.
3. **cosmic as `SHELL`** — make invokes `cosmic -c '<line>'` for every
   recipe line. lines are whitespace-split argv whose `argv[0]` must be
   a cosmic verb, or `exec` — which resolves **only to pinned bytes**.
4. **the pinned make, embedded** — extracted to `o/make` on first use.
   one binary, offline, no host toolchain. (Landed in 2e; costs ~765 KB
   on the release, uncompensated — see [plan.md](plan.md).)

```
$ cosmic --make build          # strict check, compile, stage, embed → o/bin/myapp
$ cosmic --make test           # tests, fenced, against the staged tree
$ cosmic --make fetch          # the only verb that touches the network
$ cosmic --make ci             # fmt → check → test → example → lint → coverage
```

Two sentences carry most of the design:

- **inputs = grants = your staged subtree** — what a generator may
  read, what a test may read, what the sandbox permits. corollary:
  *put it where its inputs are.*
- **a build runs only bytes you pinned, and only your code without a
  socket.** pins are data, `fetch` is the only networked verb, `exec`
  resolves only to pinned artifacts — so the external surface is
  enumerable from committed files.
