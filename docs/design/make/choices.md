# The decision table

Every question this design had to answer, and the answer it took. The
rows are the record: a question settled here is not relitigated in
passing, and one that moved says so in the [log](log/). Project-wide
tradeoffs live in [docs/decisions](../../decisions/) instead — these are
`--make`'s own.

| question | decision |
|---|---|
| primary pain | multi-file projects; tests over the code that ships. then rebuild cost/determinism, then discoverability |
| `build` semantics | strict type-check + compile + stage + embed. `test` is a separate verb |
| what tests import | the **staged tree** — the exact compiled `.lua` the artifact embeds |
| binaries per project | root `main.tl`, plus `cmd/<name>/main.tl` per artifact |
| artifact contents | root packages + its own `cmd/<name>/**`. `cmd/foo` cannot import `cmd/bar` |
| artifact output | `o/bin/<name>` |
| CLI | `cosmic --make <verb> [paths…]`, verb first |
| rules source | conventions only. no `rules.tl`. cosmic reshapes itself to fit |
| policy lanes | cosmic **verbs**, not graph rules |
| built-in opinions | none. no automatic version stamp, no automatic doc index |
| build inputs | enumerable from committed files — pins, `exec` targets, and the version stamp alike |
| generated outputs | never committed; everything generated lives in `o/` |
| generator units | directory-scoped; one per generated asset. a binary's `embed.gen.tl` fills `o/<unit>/{embed/,base}` |
| generator inputs | its containing subtree = its grants. reads outside are **denied**, not stale |
| grants | **derived** from each verb's signature; no declaration channel |
| enforcement | Landlock where available **plus** portable in-process gating |
| project root | cwd, with a loud guard if an ancestor also looks like a project |
| module root | the project root |
| public vs private | `_`-prefixed directory = importable only from within its container |
| this repo's layout | `cosmic/` is the public API; `_cli/`, `_build/`, `_make/`, `_types/`, `_perf/`, `_docs/` at root; `cmd/`; `3p/` — **landed, 3h**; `cosmic --make build` produces `o/bin/cosmic` |
| artifact layout | `/zip/<import path>.lua`, `embed/**` at the root |
| artifact contents rule | **shipping is opt-in**: modules plus `embed/**`, nothing implicit |
| `testdata/` | fixtures; not a module and not payload, so it never ships |
| paths | filenames with spaces or shell metacharacters are a validator error |
| network | only under `--make fetch`. **no project code ever runs with a socket** |
| pins | `*_pin.tl` — Teal, statically extracted from a literal, never executed |
| `exec` | resolves only to pinned/staged bytes under `o/`. never `PATH` |
| version stamp | read from the cosmos pin plus a committed `.version` (`COSMIC_VERSION` overrides); no host tool |
| recipe lines | whitespace-split argv; `argv[0]` ∈ closed verb set ∪ `exec` |
| `-c` vs `--build` | `-c` wins; `--build` retired across two release cycles |
| make's bytes | embedded in the cosmic release. amends D13 |
| provisioning | `bin/cosmic` fetches one pin here; **downstream projects commit their cosmic** |
| artifact base | `o/<unit>/base` if the unit names one, else the running cosmic, stripped to a positive floor |
| the floor | compiled `cosmic/**` + certs + zoneinfo + `.args`; verified by test |
| generated makefile | written to `o/`, documented, readable |
| generality | constant rules + generated facts (variables only) |
| staleness | mtime schedules, content decides (write-if-changed everywhere) |
| parallelism | everything parallel; spawn cost is a budget, not an excuse |
| test isolation | writes `TEST_TMPDIR` only; reads = staged subtree + staged modules |
| test selection | paths (several), expanded by the caller's shell. no filter flag |
| `ci` | fixed order, each stage gated by whether the project has material for it |

