# AGENTS.md

## Project Overview

cosmic is a batteries-included Lua distribution built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan). it produces fat-binary executables that run on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single file. the language is [Teal](https://github.com/teal-language/tl) (typed Lua) compiled to Lua 5.4.

the primary artifact is `cosmic-lua` — a single executable containing:
- Lua 5.4 runtime (via Cosmopolitan)
- Teal compiler and type checker
- a standard library (`cosmic.*` modules) for fs, networking, crypto, json, sqlite, etc.
- embedded documentation index
- build tooling for creating custom executables

the project's mission, ranked promises, and measurable goals live in
[docs/goals.md](docs/goals.md); the tradeoffs behind them are recorded
ADR-style in [docs/decisions/](docs/decisions/), one file per record.
consult both before proposing directional changes — settled decisions are amended there, not
relitigated in passing.

## Repository Layout

```
cmd/cosmic/main.tl    the binary's entry → o/bin/cosmic
cmd/cosmic/embed_gen.tl  its payload generator: what the artifact carries
embed/cosmic.mk       the rules `--make` feeds to make, shipped at /zip/cosmic.mk
cosmic/               standard library modules (*.tl) — the PUBLIC API
  init.tl              entry point helper: cosmic.main()
  fs/                  fs directory module (init, path, ops, file, walk, types)
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
                      binary, never in user artifacts (D19 amendment)
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

- **source language**: Teal (`.tl` files) — typed Lua that compiles to Lua 5.4
- **error handling**: return `value, string` (nil + error message on failure). never throw from library code.
- **doc comments**: `---` prefix with `@param` and `@return` tags
- **naming**: the charter is [D20](docs/decisions/d20-naming-charter.md); a
  deviation in new code is a bug. Headlines: `snake_case` spelled out, units in the
  identifier (`_ms`), `is_*` predicates, `Options`/`opts`, lowercase constructors.
- **formatting**: 2-space indent, LF line endings, enforced by `cosmic --check fmt`
- **column width**: 90 columns is house style and the one style rule that is NOT a
  gate (the tree has ~800 lines over it). Write to 90; expect no failure if you don't.
- **warnings are errors**: `--check types` fails on any Teal warning (unused, shadowing, unreachable branch). mark deliberately-unused values with a leading underscore (`local _out`, `_self: Poller`).
- **file length**: all files must be ≤500 lines. no exceptions. enforced
  by `cosmic --check lint`, which is what both `--make lint` and
  `cosmic --make lint` run. `.d.tl` type declaration files are exempt
  (they describe C binding interfaces and cannot be split due to Teal's
  record system).
- **test files call each test where they define it**: a `test_*` function
  in a `_test.tl` is called on the line after its `end`, so a failing run
  names the function. Helpers are exempt (they are called from the tests),
  and `Example_*` functions are called by the example runner.
- **imports**: prefer `cosmic.*` modules over raw `cosmo.*` C bindings. `cosmo.*` is only for library internals implementing wrappers.
- **tests**: `*_test.tl` files alongside source, run via `cosmic --make test`
- **examples**: `*_example.tl` files with `Example_*` functions, run via `cosmic --make example`

### cosmo vs cosmic

`cosmo` and `cosmo.*` (e.g. `cosmo.unix`, `cosmo.path`) are low-level C bindings from Cosmopolitan Libc. `cosmic.*` modules are the typed Teal wrappers with error handling and docs.

- **library internals** (`cosmic/*.tl`): use `cosmo.*` to implement wrappers. this is the one place `require("cosmo")` is expected.
- **examples, tests, scripts** (`*_example.tl`, `*_test.tl`, user scripts): always use `cosmic.*`. never call `cosmo.*` directly.

common mappings:

| cosmo | cosmic |
|-------|--------|
| `cosmo.Barf(path, data)` | `require("cosmic.fs").write(path, data)` |
| `cosmo.Slurp(path)` | `require("cosmic.fs").read(path)` |
| `cosmo.path.join(...)` | `require("cosmic.fs").join(...)` |
| `cosmo.path.isfile(p)` | `require("cosmic.fs").is_file(p)` |
| `cosmo.unix.mkdtemp(t)` | `require("cosmic.fs").temp_dir(t)` |
| `cosmo.unix.rmrf(p)` | `require("cosmic.fs").remove_all(p)` |
| `cosmo.unix.makedirs(p)` | `require("cosmic.fs").make_dirs(p)` |
| `cosmo.unix.chmod(p, m)` | `require("cosmic.fs").chmod(p, m)` |
| `cosmo.DecodeJson(s)` | `require("cosmic.json").decode(s)` |
| `cosmo.EncodeJson(v)` | `require("cosmic.json").encode(v)` |
| `cosmo.Fetch(url, opts)` | `require("cosmic.fetch").fetch(url, opts)` |

### Common Patterns

**dual-use modules with `is_main()`**: use `require("cosmic.proc").is_main()` to write files that work both as standalone scripts and as importable modules. prefer `cosmic.proc.is_main()` over the low-level `cosmo.is_main()`.

```teal
local proc = require("cosmic.proc")
local function greet(name: string): string
  return "hello, " .. name
end
if proc.is_main() then
  print(greet(arg[1] or "world"))
end
return {greet = greet}
```

### Error Handling Patterns

the pattern table and worked snippets ship in the binary
(`cosmic --docs guide.modules`, `cosmic --examples errors`); the
doctrine prose is [docs/stdlib.md](docs/stdlib.md). the shape rules:

**honest nil — the type must admit failure:**
- **Fallible value**: `T | nil, string` — the checker forces callers to narrow.
- **Fallible effect**: `boolean, string` (returns `false, msg` on failure).
- **Infallible**: bare value.

Errors are strings: failed `cosmo.unix` calls return `nil, err, errno` (a
formatted string plus the numeric errno), wrappers add context with
`errno.format(err, prefix)`, and branch on the numeric errno via
`errno.is_code(errno_value, "EINTR")`.

**Narrowing nil unions.** A guard on a plain variable narrows `T | nil` for every
`T`: truthiness (`if not r then return end`), `assert(r)`, and `== nil`/`~= nil` —
which is exact, so it narrows boolean unions the other two deliberately skip — via
the carried tl patch (`3p/tl/tl_patch.tl`; mechanism in `_make/patch.tl`). What
still does NOT narrow: record FIELDS (copy the field to a local and guard the
local) and `is` early-exit guards (`if not (x is Rec) then return end`). The other tools:

- **In tests and examples, use `check.must`** for fallible returns: `local db =
  check.must(sqlite.open(path))` yields a plain `Database` — no cast, no assert. Lua
  passes multiple returns through, so a failing call reports the callee's own error
  string. `must` narrows nil only (`false` passes through), and it throws, so it is for
  tests/examples, never library code. Like `assert`, it declares ONE return, so it
  composes anywhere a value goes — `return check.must(f())`, `g(x, check.must(f()))`,
  `for row in check.must(db:query(sql))` — with no parenthesis-truncation. Never write
  `assert(x) as T` in a test; that pattern is retired.
- **Use `is` for dispatch past nil**: `if sock is net.Socket then sock:send(...)
  end` narrows inside the positive branch (one `type(x) == "table"` check); also
  dispatch over `any` (`if v is {string: any} then`). A record whose runtime
  values are userdata needs Teal's `userdata` member in its OWN source (see
  re.tl's Regex) — then `is` compiles to a `type(x) == "userdata"` test
  everywhere (`fs.Stat` is one, so `st is fs.Stat` narrows). Caveat: `is`
  narrowing does NOT survive an early-exit guard (`if not (x is Rec) then return
  end` does not narrow below — unlike the plain truthiness guard). `is` works
  with required `cosmo.*` classes too — the cosmic searcher is the only loader
  cosmic installs, and it resolves `.d.tl` markers. The one unsupported path is
  user code calling `require("tl").loader()`, which shadows it with tl's silent one.
- **Cast in linear code and at userdata boundaries**: after an assert, `(x as Rec).field`, `(x as {K:V})[k]`.

Every `as` cast must carry a justification (enforced by `--make lint`):
a line containing a cast needs `-- cast: <reason>` trailing on the line,
or as a comment on the line directly above when the 90-column width
won't fit it. Write the actual reason (`from any`, `userdata boundary`,
`tuple element`, `record union after guard`, ...) — a cast you cannot
justify is one to remove, via `is`, `check.must`, or a precise type.

**A fallible return has TWO slots.** If slot 1 admits nil (`T | nil`, or
`any`), slot 2 is the error and there is nothing after it — enforced by the
`fallible-returns` lint, in every project cosmic builds, and settled as
[D20](docs/decisions/d20-naming-charter.md) rule 11. Extras ride on the value's
record (`fs.find`'s `.errors`, `sqlite`'s `Checkout`), never in slot 3, because
`local v, err = f()` and `check.must(f())` are the only two call shapes anyone
writes and neither can see past the second. An infallible tuple is untouched
(`string.partition` returns three strings and none of them could be an error).
A `cosmo.*` binding's tuple is not ours to fold — but it is already declared in
the generated `.d.tl`, which lint exempts by position, so name that type instead
of retyping its shape. Full rule: `cosmic --docs guide.lint`.

**`find` says whether it means a pattern.** A variable needle in
`s:find(x)` needs `, 1, true` (substring) or `, 1, false` (real
pattern) — the `find-needle` lint asks which you meant, and
`cosmic --docs guide.lint` (its shipped home) has the full rule,
including the `match`/`gmatch`/`gsub` corollary.

rules:
- never throw from library code — `cosmic.check` alone is exempt ([D23](docs/decisions/d23-check-throws.md)); D22's CSPRNG throws are the only others
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
whilp/cosmopolitan, embedded in the pinned cosmos release binary at
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

all modules are under `cosmic/` and imported as `cosmic.*`:

| module | description |
|--------|-------------|
| ansi | ANSI terminal styling. |
| check | Assertion helpers for tests with auto-formatted failure messages. |
| child | Child process management. |
| codec | Encoding and decoding utilities: bytes in, bytes out. |
| compress | Compression and decompression utilities. |
| coverage | Line coverage collection for cosmic programs. |
| deep | Deep table operations. |
| deploy | Examples for deploying cosmic scripts. |
| doc | Query the documentation index embedded in the binary. |
| embed | Embed files and directories into a cosmic executable. |
| env | Environment variables: get/set/unset/list, dotenv, and env.d loading. |
| errno | Error information from system calls. |
| errors | Examples for the error-handling doctrine every cosmic.* module follows. |
| fd | File descriptor I/O operations. |
| fetch | Structured HTTP fetch with retry, streaming, and honest error channels. |
| flags | Declarative command-line flag parsing with a generated --help. |
| format | Code formatter for Teal and Lua files. |
| fs | Unified filesystem module. |
| fuzzy | Fuzzy string matching utilities. |
| hash | Cryptographic digests, HMAC, and Argon2 password hashing. |
| html | HTML utilities. |
| instrument | Timing and resource-usage spans, one `key=value` line each. |
| ip | IP address parsing, formatting, and classification utilities. |
| json | JSON encoding and decoding utilities. |
| literal | Teal source read and written as data: one `return { … }` of literals. |
| log | Leveled logging. |
| net | Networking and socket utilities. |
| poll | Typed interface for polling file descriptors. |
| proc | Current process management. |
| quicksand | Network + filesystem process isolation primitives. |
| rand | Random bytes, integers, floats, choice, shuffle, and tokens. |
| re | Regular expression matching using POSIX extended regex syntax. |
| sandbox | One-call, fail-closed in-process sandbox: the one door (#989). |
| searcher | The cosmic-owned runtime `.tl` package searcher, replacing tl.loader(). |
| shm | Shared memory for inter-process communication. |
| signal | Signal handling utilities. |
| sqlite | Ergonomic SQLite wrapper with automatic cleanup and 1-indexed columns. |
| sse | Server-Sent Events: parse a stream of them, format one for the wire. |
| stream | The stream contract: byte-stream Reader/Writer interfaces. |
| string | String utilities. |
| sys | System information utilities. |
| tar | In-process tarball extraction, without a host `tar`. |
| teal | Teal compilation and type-checking. |
| time | Time and clock utilities. |
| tty | Terminal (TTY) utilities. |
| url | URL encoding, decoding, parsing, formatting, and escaping utilities. |
| user | User and group identity operations. |
| uuid | UUID generation utilities. |
| zip | ZIP archive reading and writing. |

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
bin/cosmic --make run _perf/run.tl --out o/perf/current.json <modules...>
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
a local whilp/cosmopolitan build), `skills/optimize/measurement.md` (noise
discipline). the backlog is GitHub issues labeled `perf`.

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
- **docs.yml**: `--make docs` then `_docs/publish.tl`, to the `docs`
  branch on push to main
- **release.yml**: daily release, built twice — the pinned cosmic builds
  one from the tree, and THAT one builds what ships, so a release is
  produced by its own code, not the pin. cron runs default to a
  prerelease; a real one needs `workflow_dispatch` with `prerelease: false`
