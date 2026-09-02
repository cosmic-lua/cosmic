# AGENTS.md

## Project Overview

cosmic is a batteries-included Lua distribution built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan). it produces fat-binary executables that run on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single file. the language is [Teal](https://github.com/teal-language/tl) (typed Lua) compiled to Lua 5.4.

the primary artifact is `cosmic-lua` — a single executable containing:
- Lua 5.5 runtime (via Cosmopolitan)
- Teal compiler and type checker
- a standard library (`cosmic.*` modules) for fs, networking, crypto, json, sqlite, etc.
- embedded documentation index
- build tooling for creating custom executables

the project's mission, ranked promises, and measurable goals live in
[docs/goals.md](docs/goals.md); the tradeoffs behind them are recorded
ADR-style in [docs/decisions/](docs/decisions/), one file per record, each carrying a `status` the derived index gates.
consult both before proposing directional changes — settled decisions are amended there, not
relitigated in passing; writing, amending, or superseding one is the `decide` skill (`skills/decide/SKILL.md`), whose form is itself a record ([D26](docs/decisions/d26-decision-records.md)).

## Repository Layout

```
cmd/cosmic/main.tl    the binary's entry → o/bin/cosmic
cmd/cosmic/embed_gen.tl  its payload generator: what the artifact carries
embed/cosmic.mk       the rules `--make` feeds to make, shipped at /zip/cosmic.mk
cosmic/               standard library modules (*.tl) — the PUBLIC API
  init.tl              entry point helper: cosmic.main()
  fs/                  fs directory module (init, path, ops, file, walk, octal, types)
  *.tl                 library modules
  *_test.tl            tests
  *_example.tl         runnable examples
_cli/                 the dispatcher behind every flag (args, help, run, ...)
  build/               the closed verb vocabulary behind `-c`
_make/                `cosmic --make`: project model, validator, root, verbs
_build/               ratchets over what the repo ships and derives
_tool/                internal toolchain modules: the runners (testrun,
                      example, benchmark), the record grammar (records),
                      the pure lint checks, coverage's ratchet half and
                      doc's extraction half — embedded in the cosmic
                      binary, never in user artifacts
_docs/                doc publishing
docs/                 prose docs; docs/guides/** SHIPS in the binary and
                      is what `cosmic --docs guide.<topic>` serves
_perf/                performance benchmark harness (see skills/optimize/)
_types/               cosmo.* type declarations (generated) + gentype generator
3p/
  cosmos/              Cosmopolitan Lua binary + zip tool
  tl/                  Teal compiler
bin/
  cosmic               trust root: POSIX sh, fetches the one pinned cosmic
                       (bin/cosmic.pin) and execs it
  cosmic.pin           that pin — url + sha256, two plain lines
.github/workflows/
  pr.yml               CI on push/PR (--make ci)
  docs.yml             publish docs on push to main
  release.yml          daily release build
  fuzz.yml             daily deep fuzz (--make test _fuzz)
```

**the repo root is the module root**:
a source's path relative to the root *is* its import path, so
`cosmic/fs/path.tl` is `require("cosmic.fs.path")` and
`_perf/harness.tl` is `require("_perf.harness")`. there is no `lib/`
between the two anymore. a leading `_` marks a tree as internal — it is
repo tooling, not the published API — which is why `_docs/` and the
markdown `docs/` can coexist. **position is the manifest**: a module is
public API exactly when it is `cosmic.<name>` with no `_` — there is no
list to maintain (`cosmic/public.tl` is gone) and none to go stale. the
rule lives in `cosmic/doc/visibility.tl`.

**`cosmic/` is the published API and nothing else**: the
dispatcher (`_cli/`) and the build system (`_make/`) sit at the root, and
the binary's entry is `cmd/cosmic/main.tl` — the same `cmd/<name>/`
position `--make` builds every binary from, so cosmic is an ordinary
project under its own rules. the consequence to know when moving code:
a module under `cosmic/` may not be required from outside `cosmic/`
unless it is public, and the strip floor is `cosmic/**`, so anything a
STRIPPED artifact must still boot with has to live there. `cosmic
--make build` at the root produces `o/bin/cosmic` today; what it does
not yet carry is in [docs/design/make/](docs/design/make/).

## Language and Conventions

- **source language**: Teal (`.tl`) — typed Lua compiled to Lua 5.4
- **error handling**: return `value, string` (nil + message on failure); never throw from library code
- **doc comments**: `---` prefix with `@param`/`@return` tags
- **naming**: charter is [D20](docs/decisions/d20-naming-charter.md), a deviation in new code is a bug — `snake_case` spelled out, units in the identifier (`_ms`), `is_*` predicates, `Options`/`opts`, lowercase constructors
- **formatting**: 2-space indent, LF endings, enforced by `cosmic --check fmt`
- **column width**: 90 is house style and the one rule that is NOT a gate; write to it, expect no failure if you don't
- **warnings are errors**: `--check types` fails on any Teal warning; mark deliberate non-use with a leading underscore (`local _out`, `_self: Poller`)
- **file length**: ≤500 lines, no exceptions, enforced by `cosmic --check lint` (`--make lint` runs it too); `.d.tl` files are exempt — C binding interfaces Teal's record system cannot split ([D39](docs/decisions/d39-no-prose-exemption-from-the-file-cap.md))
- **tests are enrolled by being defined, not by being called**: a top-level `local function test_*` in a `_test.tl` IS the enrolment — the compile seam calls every case in source order ([D29](docs/decisions/d29-tests-run-because-defined.md)); write new files in runner mode, the legacy self-calling shape is on its way out
- **imports**: prefer `cosmic.*` over raw `cosmo.*`; `cosmo.*` is for library internals implementing wrappers
- **tests**: `*_test.tl` alongside source, run via `cosmic --make test`
- **examples**: `*_example.tl` with `Example_*` functions, run via `cosmic --make example`

### cosmo vs cosmic

`cosmo` and `cosmo.*` (`cosmo.unix`, `cosmo.path`, ...) are low-level C
bindings from Cosmopolitan Libc; `cosmic.*` modules are the typed Teal
wrappers with error handling and docs.

- **library internals** (`cosmic/*.tl`): use `cosmo.*` to implement wrappers — the one place `require("cosmo")` is expected.
- **examples, tests, scripts** (`*_example.tl`, `*_test.tl`, user scripts): always use `cosmic.*`, never `cosmo.*` directly — e.g. `cosmo.Barf`/`cosmo.Slurp` are `cosmic.fs`'s `write`/`read`; `cosmic --docs <module>` serves the full mapping for every wrapper.

### Common Patterns

**dual-use modules with `is_main()`**: `require("cosmic.proc").is_main()` writes a file that works as both a standalone script and an importable module; prefer it over the low-level `cosmo.is_main()`. Worked example: `cosmic --docs guide`.

### Error Handling Patterns

the pattern table and worked snippets ship in the binary
(`cosmic --docs guide.modules`, `cosmic --examples errors`); the
doctrine prose is [docs/stdlib.md](docs/stdlib.md). the shape rules:

**honest nil — the type must admit failure:** fallible value is `T | nil,
string` (callers must narrow; the checker only makes them at an index,
`cosmic --docs guide.checking`); fallible effect is `boolean, string`
(`false, msg` on failure); infallible is a bare value.

Errors are strings by default (`nil, err, errno` from `cosmo.unix`, formatted
via `errno.format`, branched via `errno.is_code`); a module whose failures
carry structure returns **its own concrete error record** in slot 2 instead
([D24](docs/decisions/d24-structured-failures.md)) — classify by FIELD, never
`is` (unsound); render with `tostring(err)` or `.message`.
`cosmic.errors.Failure` is the sink-side supertype (`check.must` accepts
`string | Failure`).

**A fallible return has TWO slots**, nothing in a third — enforced by the
`fallible-returns` lint, settled as [D20](docs/decisions/d20-naming-charter.md)
rule 11. Extras ride on the value's record (`fs.find`'s `.errors`); a
`cosmo.*` binding's tuple is exempt by position (already in the `.d.tl`).
Narrowing a `T | nil`, `check.must`, and `is` are worked in `cosmic --docs
guide.checking` and `guide.gotchas`; `cast-justify`, `fallible-returns`, and
`find-needle` are lint rules documented in `guide.lint`.

rules:
- never throw from library code — exempt: `cosmic.check`'s assertions and
  `needs`/`reap` exits, the CSPRNG's throw-on-failure, a justified `assert`
  on an impossible `cosmo.*` nil ([D23](docs/decisions/d23-check-throws.md)),
  and D30's three boundaries — a Lua protocol whose error channel is the
  throw, a process boundary with no caller, an infallible-by-type contract
  violation ([D30](docs/decisions/d30-throw-exit-boundaries.md)); each site
  carries a trailing `-- assert:`/`-- throws:`/`-- exits: <why>`
- never silently discard errors
- be consistent within a module — pick one pattern and use it throughout
- infallible functions (encoding, compression, escaping) return just a value

## Build System

`cosmic --make` builds this repo, by the same conventions it builds any
project. There is no Makefile, no `cook.mk`, no build spec: the tree is
the project, and a file's position and name say what it is.

```bash
bin/cosmic --make fetch     # resolve *_pin.tl — the only verb with a network
bin/cosmic --make ci        # fmt, check, example, lint, coverage
bin/cosmic --make test      # …or one stage; add paths to narrow it
bin/cosmic --make build     # just the binaries
bin/cosmic --make clean     # remove o/
```

**One command, always correct** — `bin/cosmic --make ci` — because a
gate verb in this project CONVERGES before it runs. A gate's result is
a statement about a toolchain, and this project builds the toolchain:
run `fmt` under the pinned release and it formats with the release's
formatter, so a formatter fix passes its own gate. So the tool builds
first and re-execs into what it built, capped at two generations, with
a loud `not a fixpoint` if a third would be needed
(`_make/converge.tl`). `bin/cosmic` prefers `o/bin/cosmic` when one
exists and reaches for the pin only on a cold start.

**The cold-build rule** is convergence's flip side: build generation 1
compiles the WHOLE tree — not just `cosmic/**` — with the pinned
release's checker and patch set, so a source that needs the tree's own
checker (a new narrowing rule, a new patch entry) passes the converged
`--make ci` and fails only a cold build. Such a change stages behind a
release and pin bump: land the checker first, bump `bin/cosmic.pin` to
a release carrying it, then land the code that needs it.
`_build/coldbuild_test.tl` enforces this — generation 1's exact type
check, pinned checker with tree module resolution — so the failure
lands on the PR instead of in CI's `build` lane.

key concepts:
- **conventions, not declarations**: `*_test.tl` is a test, `*_example.tl`
  an example, `*_benchmark.tl` a benchmark, `*_pin.tl` a pin, `*_gen.tl`
  a generator, `cmd/<name>/embed_gen.tl` a binary's payload generator,
  `embed/**` payload, `cmd/<name>/main.tl` a binary, a leading `_`
  internal, `testdata/` never embedded. Nothing lists these; position
  declares them
- **generators run before the graph**: a `*_gen.tl` writes an INPUT — the
  checker, compiler, formatter and linter all read what `_types/types_gen.tl`
  produces — so every verb that touches the graph runs the generators
  first. A binary's `embed_gen.tl` is the other way round: it packs what
  the graph produced, so it runs last
- **versioned deps**: 3p modules declare a `*_pin.tl` — literal data, read
  by `cosmic.literal` and never executed. `fetch` unpacks a pin beside
  the pin, so cosmos lands in `o/3p/cosmos/` and tl in `o/3p/tl/`
- **trust root**: `bin/cosmic` is POSIX sh and obtains exactly one pinned
  artifact (`bin/cosmic.pin`), verifies its sha256 and execs it. Cosmic
  extracts its own build engine from its own zip, so the chain is
  kernel → script → one pin → everything else
- **constant rules, generated facts**: `embed/cosmic.mk` is committed,
  ships at `/zip/cosmic.mk`, and is byte-identical for every project. No
  rule is ever generated. `o/project.mk` holds only variable assignments —
  `srcdeps_<stem>`, each source's transitive import closure — so a module
  whose contract changed recompiles its importers. Never commit it
- **cosmic as `SHELL`**: make runs `cosmic -c '<line>'`. A recipe line is
  argv, not shell — whitespace-split, `argv[0]` a verb from a closed
  vocabulary (`_cli/build/`), metacharacters refused rather than
  interpreted — and cosmic derives its sandbox grants from it
- **a variant is a base beside a base**: a unit's output directory holds
  `embed/` (what the artifact carries) next to `base` (what it carries it
  on). A `base-<variant>` ships the SAME staged payload on that runtime
  as `o/bin/<name>-<variant>`, which is how one build makes both release
  binaries
- **output directory**: all build artifacts go to `o/`

**`_perf` is not `--make benchmark`.** `*_benchmark.tl` holds
`Benchmark_*` functions the runner extracts and times one at a time;
`_perf/bench/*_bench.tl` are scenario MODULES for a harness that
aggregates across them. This repo's performance work is the latter.

## Type Generation

the `cosmo.*` and `tl` type declarations are GENERATED and **not
committed**. `_types/types_gen.tl` is a generation unit; every verb that
touches the graph runs it first, into `o/_types/types_gen/` — the
directory that generator owns. Inside it: `cosmo.d.tl` (the top-level
`require("cosmo")` surface), `cosmo/*.d.tl` (unix, path, getopt,
lsqlite3, re, argon2, zip, repl) and `tl.d.tl` (the narrowed public
Teal compiler API).

Nothing to regenerate and no drift to check: the build produces them,
and a `cosmo.*` change shows up as the pin bump that caused it. The cost,
stated: **a fresh clone cannot resolve `cosmo.*` until it has fetched and
built once**, and an editor needs `o/_types/types_gen` on its include path.

the single source of truth for `cosmo.*` is `tool/net/definitions.lua` in
cosmic-lua/cosmopolitan, embedded in the pinned cosmos release binary at
`/zip/.lua/definitions.lua`. upstream, per-module annotation-coverage
ratchet tests guarantee every C binding is annotated; here,
`_types/gentype.tl` parses those annotations into Teal records. `tl.d.tl`
is extracted from the pinned tl source by `_types/gentl.tl`, with
internal types erased by rule and records curated to verified field
subsets.

update procedure (after a cosmos or tl pin bump):

```bash
bin/cosmic --make fetch     # land the new pin
bin/cosmic --make build     # regenerates o/_types/types_gen from it
o/bin/cosmic --make ci      # fix whatever the new types break
```

`GENTYPE_DEFS=/path/to/definitions.lua` overrides the definitions source
for validating against a cosmopolitan checkout before a release is cut.

## cosmic Binary

the cosmic binary is an executable zip. it embeds:
- compiled `.lua` modules in `cosmic/` — the zip root IS the module
  root, so `require("cosmic.fs")` resolves to `/zip/cosmic/fs.lua`
- Teal compiler in `tl.lua`
- type definitions in `.types/` (include-path payload, not modules —
  dot-prefixed names stay out of the module root)
- doc index in `.docs/index.lua`
- entry point: `/zip/main.lua` (compiled from `cmd/cosmic/main.tl`)

the CLI surface is `sys/help.md`, which is what `--help` prints.
`cosmic --make help` lists the verbs, and which of them are still
planned.

## Standard Library Modules

the standard library lives under `cosmic/` and imports as `cosmic.*`
(`require("cosmic.fs")`, `require("cosmic.json")`). the authoritative
list with one-line descriptions is served by the binary: `cosmic
--docs` prints every module, `cosmic --docs <module>` one module's
reference, and a module's description is its H1 first line — fix a
description at the module header, never in prose here.


## `--make` fixtures

`_make/testdata/**` holds hello-world-sized projects — one per behaviour
(`hello`, `pkg`, `multi`, `luaonly`, `assets`) — that
`_make/fixtures_test.tl` checks, builds and runs. They have their own
roots, so this repo's model does not see them, and they are the fastest
way to try a `--make` change by hand:

```bash
cp -r _make/testdata/hello /tmp/h && cd /tmp/h
$OLDPWD/o/bin/cosmic --make build && ./o/bin/hello
```

## Testing

**Reading gate results**: `--make ci` signals via exit code AND ends with
a `ci: PASS` / `ci: FAIL (stages)` verdict line. Never launder a gate's
exit status through a pipe (`--make ci | tail` returns tail's status) —
use `set -o pipefail`, or read the verdict line, which survives any
truncation.

```bash
o/bin/cosmic --make test                # all tests
o/bin/cosmic --make coverage            # tests + line coverage, ratcheted vs .cosmic-coverage
o/bin/cosmic --make coverage --baseline # rewrite the committed floor
o/bin/cosmic --make test cosmic/string_test.tl   # narrow by path
o/bin/cosmic --make example             # run Example_* functions
o/bin/cosmic --make benchmark           # run every *_benchmark.tl
```

**The `.cosmic-coverage` floor is recorded in one environment, not
yours**: CI's `ci` lane in `.github/workflows/pr.yml` — a digest-pinned
`buildpack-deps:noble` container, run `--privileged`, built and gated as
the non-root `builder` user, network-fenced to loopback after `fetch`.
Coverage is environment-sensitive (`cosmic/coverage/SENSITIVITY.md`):
root vs. non-root, Landlock, Linux namespaces, a real tty, a free port,
and even which compiler built the binary under test all move rows,
sometimes by 2x. `--make coverage --baseline` therefore **refuses**
anywhere `COSMIC_COVERAGE_ENV=1` is not set — that lane sets it for
itself; a developer's machine never should. Move the one row your
change actually affects by hand-editing its `covered`/`total` pair in
`.cosmic-coverage` directly; a whole-floor rewrite is only for the
recording environment itself.

test files use a simple assertion pattern:
```teal
local str = require("cosmic.string")

local function test_trim()
  local result = str.trim("  x  ")
  assert(result == "x", "got: " .. tostring(result))
end
test_trim()
```

each test gets its own temp directory via `TEST_TMPDIR`.

`_make/fixpoint_test.tl` (two full builds) is gated: run it with
`COSMIC_FIXPOINT=1 bin/cosmic --make test _make/fixpoint_test.tl`.

## Performance

`_perf` holds the scenario harness: end-to-end scenarios (JSON, SQLite,
HTTP, fs, crypto/codecs, binary startup) with per-scenario functional
checks, a JSON results format, and a noise-aware comparison gate.

```bash
# `--make run` builds first and resolves the harness AND the scenarios
# against the tree; bare scripts load the binary's embedded copies.
bin/cosmic --make run _perf/run.tl --out o/perf/current.json  # all bench modules
bin/cosmic --make run _perf/gate.tl compare BASE.json CUR.json SELFB.json
bin/cosmic --make run _perf/gate.tl selfcheck A.json B.json  # A/A noise floor
```

all performance work follows the loop in the `optimize` skill
(`skills/optimize/SKILL.md`): baseline →
hypothesis → change → `--make ci` (correctness/style gate) →
the compare gate (regression) → keep or revert. never weaken a
scenario or its check to make numbers pass; never commit `o/perf/*.json`.

the manual is split by chapter: `skills/optimize/finding.md` (spotting
cosmic-layer wins), `skills/optimize/cosmopolitan.md` (the C layer against
a local cosmic-lua/cosmopolitan build), `skills/optimize/measurement.md` (noise
discipline). the backlog is perf hypotheses on the work board.

## The flow of work

what to build next is decided by the `work` skill (`skills/work/SKILL.md`):
one prioritized queue of items in two states — `todo` and `doing` (claimed) —
with quality held by a spec bar at pull and a fresh-context review before
merge, not by stage columns. the board lives on the orphan `board` branch —
one `items/<ksuid>.tl` per item, the machinery beside it — reached as a worktree.
the skill has the bootstrap; the tool serves the system itself —
`gitboard help <topic>` for the doctrine, `gitboard help <verb>` for the
mechanics, `gitboard brief` for subagent prompts. issues remain only the
inbound queue; pull requests carry fixes and review as before.

## CI

- **pr.yml**: four lanes on push/PR to main. `ci` fetches with a network, then builds
  and runs the whole gate (fmt, check, example, lint, coverage) inside a loopback-only
  network namespace, so a stray download fails loudly — tests run once, instrumented, via
  the coverage stage's ratchet. It builds first and gates with the RESULT, or the five
  stages would report on the pinned release instead of the change. `build` builds with a
  real network, asserts the fixpoint and that the host can enforce the fence (every build
  here runs fenced by default; `COSMIC_FENCE=0` opts out, `_cli/fence_test.tl` asserts a
  real denial). `repro` — a fresh container, so a cold tree by construction — refetches
  the real pins, rebuilds at another path, and byte-compares against `build`'s artifact.
  `smoke` runs that artifact on real macOS/Windows runners. All Linux lanes are
  privileged and non-root: the quicksand tests unshare and mount, identity moves coverage
- **docs.yml**: `--make docs` then `_docs/publish.tl`, to the `docs` branch on push to main
- **release.yml**: daily release, built twice — the pinned cosmic builds one from the tree, and
  THAT one builds what ships, so a release is produced by its own code, not the pin. cron runs
  default to a prerelease; a real one needs `workflow_dispatch` with `prerelease: false`
- **fuzz.yml**: daily deep fuzz, `0 9 * * *` (three hours after release.yml's `0 6`, so the two never contend). `_fuzz` at FUZZ_ITERS=50000 (2000 on its own `pull_request` trigger), seeded `date -u +%Y%m%d` unless a `workflow_dispatch` input overrides it for replay; a red run fails loudly but never blocks or delays a release
