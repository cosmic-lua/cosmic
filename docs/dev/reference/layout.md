# Repository layout

every top-level entry, the rules that give a path its meaning, and what
the build and the binary hold. for a contributor finding where a thing
lives.

## top level

| entry | holds |
|---|---|
| `cmd/cosmic/main.tl` | the binary's entry; builds to `o/bin/cosmic` |
| `cmd/cosmic/embed_gen.tl` | the binary's payload generator: what the artifact carries |
| `embed/cosmic.mk` | the rules `--make` feeds to make; ships at `/zip/cosmic.mk`, byte-identical for every project |
| `cosmic/` | the standard library, the public API: `*.tl` modules, `*_test.tl` beside them, `*_example.tl` beside them; `init.tl` is `cosmic.main()`; `fs/` is a directory module |
| `_cli/` | the dispatcher behind every flag; `_cli/build/` is the closed verb vocabulary behind `-c` |
| `_make/` | `cosmic --make`: project model, validator, root, verbs; `_make/testdata/` holds the fixture projects |
| `_build/` | ratchets over what the repo ships and derives, and the committed floors they hold |
| `_tool/` | internal toolchain modules: the runners (testrun, example, benchmark), the record grammar, the lint checks, coverage's ratchet half, doc's extraction half; embedded in the cosmic binary, never in user artifacts |
| `_docs/` | doc publishing, and the shared halves of the docs gates: the fence checks and the derived regions |
| `_perf/` | the performance scenario harness; `_perf/bench/*_bench.tl` are its scenario modules |
| `_types/` | the `cosmo.*` and `tl` type generators (`types_gen.tl`, `gentype.tl`, `gentl.tl`) |
| `_eval/` | the agent-eval harness: `skills/agent-eval/` drives it |
| `_fuzz/` | the fuzzers; `--make test _fuzz` runs them, `FUZZ_ITERS` and `FUZZ_SEED` shape a run |
| `3p/cosmos/` | the pin for the Cosmopolitan `lua`, `make`, `zip` and `unzip` binaries, and its test |
| `3p/tl/` | the pin for the Teal compiler, its test, and `tl_patch/`, the carried edits to it |
| `bin/cosmic` | the trust root: POSIX sh that fetches the one pinned cosmic and execs it |
| `bin/cosmic.pin` | that pin: `url` and `sha256`, two plain lines |
| `docs/` | prose, one kind per directory (table below) |
| `skills/` | the agent skills: `decide`, `docs-style`, `optimize`, `work`, `agent-eval` |
| `sys/help.md` | the CLI surface; `--help` prints it |
| `env.d/` | environment files `cosmic.env` loads |
| `.github/workflows/` | `pr.yml`, `docs.yml`, `release.yml`, `fuzz.yml` ([ci.md](ci.md)) |
| `AGENTS.md` | the project instructions; `CLAUDE.md` is a symlink to it |
| `.cosmic-coverage` | the committed coverage floor |
| `tlconfig.lua` | editor and LSP include path only; the build never reads it |
| `o/` | every build output; never committed |

### `docs/`

| directory | kind | ships |
|---|---|---|
| `docs/tutorial/` | a lesson the reader follows to a working result | yes, as `cosmic --docs tutorial.<topic>` |
| `docs/howto/` | steps for one task | yes, as `howto.<topic>` |
| `docs/reference/` | the facts, in the structure of the thing described | yes, as `reference.<topic>` |
| `docs/explanation/` | why things are the way they are | yes, as `explanation.<topic>` |
| `docs/dev/<kind>/` | the same four kinds, for contributors | no |
| `docs/goals.md` | the mission, the ranked promises, the measured goals | no |
| `docs/decisions/` | one record per settled tradeoff | no |

## the module-root rule

the repo root is the module root. a source's path relative to the
root, with `/` as `.` and the extension dropped, is its import path.

| path | import |
|---|---|
| `cosmic/fs/path.tl` | `require("cosmic.fs.path")` |
| `cosmic/fs/init.tl` | `require("cosmic.fs")` |
| `_perf/harness.tl` | `require("_perf.harness")` |

the zip root is the module root too, so the rule holds inside the
artifact: `require("cosmic.fs")` resolves to `/zip/cosmic/fs.lua`.

## the `_` rule

a leading `_` on a directory or file marks it internal to its
container. `_cli/` and `_make/` are repo tooling, not API, and say so
in their names. a module is public exactly when it is `cosmic.<name>`
for one segment that does not start with `_`; `is_public` in
`cosmic/doc/visibility.tl` is the rule, and `_build/public_surface.tl`
counts what the tree carries against
`_build/public_surface_baseline.tl`.

## position markers

| marker | declares |
|---|---|
| `*_test.tl` | a test |
| `*_example.tl` | an example: `Example_*` functions with `-- Output:` blocks |
| `*_benchmark.tl` | a benchmark: `Benchmark_*` functions |
| `*_pin.tl` | a pinned external asset |
| `*_gen.tl` | a generation unit; runs before the graph, owns `o/<its path minus .tl>/` |
| `cmd/<name>/main.tl` | a binary, `o/bin/<name>` |
| `cmd/<name>/embed_gen.tl` | that binary's payload generator; runs after the graph |
| `embed/**` | payload, embedded at its path inside `embed/` |
| `testdata/` | fixtures; never embedded |
| `*.d.tl` | type-only; on the include path, never embedded, and exempt from the 500-line cap |

[docs/reference/make.md](../../reference/make.md) has the full project model.

## `o/`

| path | holds |
|---|---|
| `o/bin/cosmic`, `o/bin/cosmic-debug` | the built binaries |
| `o/bootstrap/cosmic` | the pinned release, assimilated; `o/bootstrap/cosmic.pin` is the sha it was verified against |
| `o/3p/cosmos/`, `o/3p/tl/` | the fetched pins, unpacked beside their position |
| `o/_types/types_gen/` | the generated type declarations (below) |
| `o/<tree>/**.lua` | compiled modules, mirroring the tree |
| `o/project.mk` | variable assignments only: `srcdeps_<stem>`, each source's transitive import closure |
| `o/cosmic.mk`, `o/make` | the rules and the engine, extracted from the running binary's zip |
| `o/<test>.tl.test.got`, `.out`, `.err` | a test's exit code, stdout and stderr |

### `o/_types/types_gen/`

generated by `_types/types_gen.tl` on every graph verb, never
committed. a fresh clone cannot resolve `cosmo.*` until it has fetched
and built once, and an editor needs this directory on its include
path.

| file | declares |
|---|---|
| `cosmo.d.tl` | the top-level `require("cosmo")` surface |
| `o/_types/types_gen/cosmo/unix.d.tl`, `path`, `getopt`, `lsqlite3`, `re`, `argon2`, `zip`, `repl`, `cov` | one `cosmo.<module>` each, from `definitions.lua` in the pinned cosmos `lua` |
| `tl.d.tl` | the narrowed public Teal compiler API, from the pinned tl source |

## the binary's `/zip`

the cosmic binary is an executable zip. Cosmopolitan maps the archive
at `/zip/` at run time.

```text
/zip/
  main.lua           the entry, compiled from cmd/cosmic/main.tl
  cosmic/**.lua      the compiled library; the zip root is the module root
  cosmic/_version.lua  the stamp --version prints
  _cli/ _make/ _tool/ ...  the compiled internal trees
  tl.lua             the Teal compiler, from the pinned tarball
  .tl_ast.luac       its pre-parsed stdlib ASTs
  .tl/**             cosmic's sources, so a user project's --check types resolves cosmic.*
  .types/**          the generated cosmo.* declarations, same reason
  .docs/index.lua    the index --docs searches
  make               the graph engine, from the pinned cosmos zip
  cosmic.mk          the rules --make feeds to make
  sys/help.md        the --help text
  docs/<kind>/**     the four shipped kinds of page
  .args              default command-line arguments
```

dot-prefixed names stay out of the module root. `docs/dev/**` and
`docs/decisions/` are not in the archive.
