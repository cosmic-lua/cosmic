# The decision table

every question the `--make` design answers, and the answer it holds,
for a contributor about to propose a change to one of them.

a row here is settled. a change to a row is a change to this table,
made on purpose, not a drift in passing. rows marked `planned`
describe something the design names and the binary does not implement
yet. tradeoffs that belong to the whole project live in
[decisions](../../../decisions/); these are `--make`'s own.

| question | decision |
|---|---|
| what it optimizes for | multi-file projects, and tests over the code that ships. then rebuild cost and determinism. then discoverability |
| `build` semantics | strict type-check, compile, stage, embed. `test` is a separate verb |
| what tests import | the staged tree: the exact compiled `.lua` the artifact embeds |
| binaries per project | `cmd/<name>/main.tl` per artifact. a root `main.tl` is refused |
| artifact contents | root packages plus its own `cmd/<name>/**`. `cmd/foo` cannot import `cmd/bar` |
| artifact output | `o/bin/<name>`, and `o/bin/<name>-<variant>` for each `base-<variant>` the unit writes |
| CLI | `cosmic --make <verb> [paths…]`, verb first |
| rules source | conventions only. no rules file. cosmic reshapes itself to fit |
| policy lanes | cosmic verbs, never graph rules |
| built-in opinions | none. no automatic version stamp, no automatic doc index |
| build inputs | enumerable from committed files: pins, `exec` targets and the version stamp alike |
| generated outputs | never committed. everything generated lives in `o/` |
| generator units | directory-scoped, one per generated asset. a binary's `embed_gen.tl` fills `o/<unit>/embed_gen/{embed/,base}` |
| when generators run | a `*_gen.tl` runs before the graph; what it writes is an input to it. a binary's `embed_gen.tl` runs after |
| the `cosmo.*` and `tl` types | generated into `o/_types/types_gen/` by `_types/types_gen.tl`, not committed. the cost: a fresh clone cannot resolve `cosmo.*` until it has fetched and built once, and an editor needs `o/_types/types_gen` on its include path. the gain: no drift test, no regen verb, no diff where output and intent look alike |
| generator inputs | its containing subtree is its grant set. a read outside it is denied, not stale |
| grants | derived from each verb's signature. there is no grant declaration channel |
| enforcement | Landlock where the host has it. a portable in-process gate for other hosts is `planned` |
| the fence default | on. `COSMIC_FENCE=0` opts out |
| project root | the current directory, with a loud refusal if an ancestor also looks like a project. `COSMIC_MAKE_ROOT` names one explicitly |
| module root | the project root |
| public vs private | a `_`-prefixed directory is importable only from within its container |
| this repo's layout | `cosmic/` is the public API. `_cli/`, `_build/`, `_make/`, `_tool/`, `_types/`, `_perf/`, `_docs/` sit at the root beside `cmd/` and `3p/`. `cosmic --make build` produces `o/bin/cosmic` |
| artifact layout | `/zip/<import path>.lua`, with `embed/**` at the zip root |
| artifact contents rule | shipping is opt-in: modules plus `embed/**`, nothing implicit |
| `testdata/` | fixtures. not a module and not payload, so it never ships |
| paths | a filename with whitespace is a validator error |
| network | only under `--make fetch`. no project code ever runs with a socket |
| pins | `*_pin.tl`: a Teal literal, statically extracted, never executed |
| patches | `<stem>_patch.tl` beside an archive pin: exact find-and-replace edits, applied after the digest matches |
| `exec` | resolves only to pinned or staged bytes under `o/`. never `PATH` |
| version stamp | read from the cosmos pin and a committed `.version`. `COSMIC_VERSION` overrides; `unknown` otherwise. no host tool |
| recipe lines | whitespace-split argv. `argv[0]` is a verb from the closed set, or `exec` |
| the recipe entry | `cosmic -c '<line>'`, the one dispatcher |
| make's bytes | embedded in the cosmic release and extracted to `o/make`. `COSMIC_MAKE` names another; `PATH` is never searched |
| provisioning | `bin/cosmic` fetches one pin (`bin/cosmic.pin`) into `o/bootstrap/cosmic`. downstream projects commit their cosmic |
| artifact base | `o/<unit>/embed_gen/base` when the unit names one, else the running cosmic stripped to the floor |
| the floor | compiled `cosmic/**`, `cosmic.lua`, `usr/` (TLS roots and zoneinfo), `.args`, `.cosmo`. verified by test |
| the generated makefile | written to `o/`, readable, never committed |
| generality | constant rules plus generated facts, which are variables only |
| staleness | mtime schedules, content decides. tool stamps and a content-keyed skip hold the line where mtimes lie |
| parallelism | `-j<nproc>` always. `COSMIC_JOBS` overrides the count |
| test isolation | writes: the test's `.got` base and `TEST_TMPDIR`. reads: the project plus an enumerated runtime list |
| test selection | paths, several, expanded by the caller's shell. no filter flag |
| `ci` | a fixed order, each stage gated by whether the project has material for it. runs to the end |
| policy verbs beyond `ci` and `coverage` | `enforce`, `reproducible`, `offline`: `planned` |
| deferred, on evidence | an action cache, port isolation, `--make explain`, single-arch artifacts: `planned` |
