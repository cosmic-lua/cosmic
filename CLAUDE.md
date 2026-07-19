# AGENTS.md

## Project Overview

cosmic is a batteries-included Lua distribution built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan). it produces fat-binary executables that run on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single file. the language is [Teal](https://github.com/teal-language/tl) (typed Lua) compiled to Lua 5.4.

the primary artifact is `cosmic-lua` — a single executable containing:
- Lua 5.4 runtime (via Cosmopolitan)
- Teal compiler and type checker
- a standard library (`cosmic.*` modules) for fs, networking, crypto, json, sqlite, etc.
- embedded documentation index
- build tooling for creating custom executables

## Repository Layout

```
Makefile              top-level build orchestration
cook.mk               module definitions (bootstrap, type gen)
lib/
  cook.mk              aggregates lib/* modules
  cosmic/              standard library modules (*.tl)
    cook.mk            builds the cosmic binary
    init.tl            entry point: cosmic.main()
    public.tl          PUBLIC manifest: public vs internal modules
    cli/               CLI internals (main.tl dispatcher, help, style, ...)
    fs/                fs directory module (init, path, ops, file, walk, types)
    *.tl               library modules
    *_test.tl          tests
    *_example.tl       runnable examples
  build/               build infrastructure (fetch, stage, reporter)
  docs/                doc publishing
  perf/                performance benchmark harness (see lib/perf/OPTIMIZE.md)
  types/               cosmo.* type declarations (generated) + gentype generator
3p/
  cosmos/              Cosmopolitan Lua binary + zip tool
  tl/                  Teal compiler
bin/
  make                 bootstrap script that downloads landlock-make
  cosmo-make           landlock-make binary (gitignored, downloaded)
.github/workflows/
  pr.yml               CI on push/PR (make ci)
  docs.yml             publish docs on push to main
  release.yml          daily release build
```

## Language and Conventions

- **source language**: Teal (`.tl` files) — typed Lua that compiles to Lua 5.4
- **error handling**: return `value, string` (nil + error message on failure). never throw from library code.
- **doc comments**: `---` prefix with `@param` and `@return` tags
- **naming**: `snake_case` for functions and variables. `PascalCase` for record types and record constructors (e.g. `signal.Sigset()`); options records are named `Options` (or `<Thing>Options` when a module has several).
- **formatting**: 2-space indent, LF line endings, enforced by `cosmic --check-format`
- **warnings are errors**: `--check-types` fails on any Teal warning (unused, shadowing, unreachable branch). mark deliberately-unused values with a leading underscore (`local _out`, `_self: Poller`).
- **file length**: all `.tl` files must be ≤500 lines. no exceptions. enforced by `bin/make lint`. `.d.tl` type declaration files are exempt (they describe C binding interfaces and cannot be split due to Teal's record system).
- **imports**: prefer `cosmic.*` modules over raw `cosmo.*` C bindings. `cosmo.*` is only for library internals implementing wrappers.
- **tests**: `*_test.tl` files alongside source, run via `make test`
- **examples**: `*_example.tl` files with `Example_*` functions, run via `make example`

### cosmo vs cosmic

`cosmo` and `cosmo.*` (e.g. `cosmo.unix`, `cosmo.path`) are low-level C bindings from Cosmopolitan Libc. `cosmic.*` modules are the typed Teal wrappers with error handling and docs.

- **library internals** (`lib/cosmic/*.tl`): use `cosmo.*` to implement wrappers. this is the one place `require("cosmo")` is expected.
- **examples, tests, scripts** (`*_example.tl`, `*_test.tl`, user scripts): always use `cosmic.*`. never call `cosmo.*` directly.

common mappings:

| cosmo | cosmic |
|-------|--------|
| `cosmo.Barf(path, data)` | `require("cosmic.fs").write(path, data)` |
| `cosmo.Slurp(path)` | `require("cosmic.fs").read(path)` |
| `cosmo.path.join(...)` | `require("cosmic.fs").join(...)` |
| `cosmo.path.isfile(p)` | `require("cosmic.fs").isfile(p)` |
| `cosmo.unix.mkdtemp(t)` | `require("cosmic.fs").mkdtemp(t)` |
| `cosmo.unix.rmrf(p)` | `require("cosmic.fs").rmrf(p)` |
| `cosmo.unix.makedirs(p)` | `require("cosmic.fs").makedirs(p)` |
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
return { greet = greet }
```

### Error Handling Patterns

most functions return `value, string` — nil + error message on failure:

```teal
local function decode(str: string): any, string
  local result, err = cosmo.DecodeJson(str)
  return result, err as string
end
```

boolean success/fail:

```teal
function db:exec(sql: string): boolean, string
  local rc = raw_db:exec(sql)
  if rc ~= sqlite3.OK then
    return false, raw_db:errmsg()
  end
  return true
end
```

use Result records for complex operations with multiple error states:

```teal
local record Result
  ok: boolean
  status: number
  headers: {string:string}
  body: string
  error: string
end
```

**honest nil — the type must admit failure:**
- **Fallible value**: `T | nil, string` — the checker forces callers to narrow.
- **Fallible effect**: `boolean, string` (returns `false, msg` on failure).
- **Infallible**: bare value.

Errors are strings: failed `cosmo.unix` calls return `nil, err, errno` (a
formatted string plus the numeric errno), wrappers add context with
`errno.str(err, prefix)`, and branch on the numeric errno via
`errno.is(errno_value, "EINTR")`.

**Narrowing record/map unions.** Teal (0.24.8) does not flow-narrow record
or map unions through truthiness (`if not x`). Two sanctioned tools:

- **Prefer `is` where the code branches, for table-backed records**:
  `if sock is net.Socket then sock:send(...) end` narrows `Socket | nil`
  inside the positive branch (compiles to one `type(x) == "table"` check).
  Also works for dispatch over `any` (`if v is {string: any} then`).
  A record whose runtime values are userdata needs Teal's `userdata`
  member in its OWN source (see re.tl's Regex) — then `is` compiles to
  the correct `type(x) == "userdata"` test everywhere. Caveats:
  narrowing does NOT survive an early-exit guard (`if not (x is Rec)
  then return end` does not narrow below); and `is` is WRONG for
  mixed-representation records — `fs.Stat` is usually the raw stat
  userdata but falls back to a plain wrapper table, so neither marker
  fits; it stays on casts. (The ban on `is` with REQUIRED `cosmo.*`
  classes is NARROWED, not lifted: under the cosmic dispatcher the
  runtime searcher (#669) resolves .d.tl markers, so `is` cannot
  degrade there — but stdlib modules that EMBEDDED apps may recompile
  via the documented `require("tl").loader()` main.lua pattern bypass
  the cosmic searcher and still degrade; those keep casts, e.g.
  fs.opendir.)
- **Cast in linear code and at userdata boundaries**: after an assert or
  early-exit guard, `(x as Rec).field`, `(x as {K:V})[k]`. Scalars
  (`string | nil`) narrow normally, except method-call syntax: use
  `string.sub(x, …)` not `x:sub(…)` on a narrowed value.

Total `as` casts are pinned per file by `lib/build/casts.txt` (the
cast ratchet, enforced by `bin/make lint`): adding a cast means raising the
pin deliberately; removing casts means running `bin/make casts-baseline`
to lock the improvement in.

rules:
- never throw from library code
- never silently discard errors
- be consistent within a module — pick one pattern and use it throughout
- infallible functions (encoding, compression, escaping) return just a value

## Build System

the build uses GNU Make with a module system defined in `cook.mk` files.

```bash
bin/make help           # show all targets
bin/make build          # build cosmic binary
bin/make test           # run all tests (incremental)
bin/make teal           # type check all files
bin/make format         # check formatting
bin/make ci             # full CI: format + teal + test + example + lint + coverage
bin/make docs           # generate markdown docs from source
bin/make clean          # remove build artifacts
```

key concepts:
- **modules**: each directory declares a module via `cook.mk` with `_tl`, `_tests`, `_files`, `_deps`
- **versioned deps**: 3p modules use `version.lua` → fetch → stage pipeline
- **bootstrap**: a pre-built cosmic binary bootstraps compilation of `.tl` → `.lua`
- **sandboxing**: landlock-make applies pledge/unveil per-rule for build isolation
- **output directory**: all build artifacts go to `o/`

## Type Generation

the `cosmo.*` type declarations are GENERATED — never edit them by hand:

- `lib/types/cosmo.d.tl` — the top-level `require("cosmo")` surface
- `lib/types/cosmo/*.d.tl` — submodules (unix, path, getopt, lsqlite3, re, argon2, zip, repl)

the single source of truth is `tool/net/definitions.lua` in whilp/cosmopolitan,
embedded in the pinned cosmos release binary at `/zip/.lua/definitions.lua`.
upstream, per-module annotation-coverage ratchet tests guarantee every C
binding is annotated; here, `lib/types/gentype.tl` parses those annotations
into Teal records, and `lib/types/gentype_test.tl` fails if the committed
files differ byte-for-byte from generator output.

update procedure (after a cosmos bump or generator change):

```bash
# 1. bump 3p/cosmos/version.lua (url version + sha)
bin/make regen-types      # regenerate all .d.tl from the new pin
bin/make test only=gentype
# 2. fix any lib/cosmic wrappers the new types break; commit everything together
```

`GENTYPE_DEFS=/path/to/definitions.lua` overrides the definitions source for
validating against a cosmopolitan checkout before a release is cut.

`lib/types/tl.d.tl` (Teal compiler API) is generated too — by
`lib/types/gentl.tl` from the staged tl source (`bin/make regen-tl-types`
after a tl version bump; `gentl_test.tl` fails on drift). The one
handcrafted exception is `lib/types/make-help.d.tl`.

## cosmic Binary

the cosmic binary is an executable zip. it embeds:
- compiled `.lua` modules in `.lua/cosmic/`
- Teal compiler in `.lua/tl.lua`
- type definitions in `.lua/types/`
- doc index in `.docs/index.lua`
- entry point: `/zip/main.lua` (compiled from `lib/cosmic/cli/main.tl`)

CLI features:
```
cosmic script.tl              run a Teal script
cosmic --compile file.tl      compile to Lua (stdout)
cosmic --check-types file.tl  type check (strict)
cosmic --check-format file    check formatting
cosmic --format file          format file (stdout)
cosmic --docs <query>         search documentation
cosmic --examples [module]    browse examples
cosmic --test <out> <cmd>     run test, capture output
cosmic --report <paths>       report test results
cosmic --embed <path>         embed files into executable
cosmic --benchmark file.tl    run benchmarks
cosmic -i                     interactive REPL
```

## Standard Library Modules

all modules are under `lib/cosmic/` and imported as `cosmic.*`:

| module | description |
|--------|-------------|
| ansi | ANSI terminal styling: colors, attributes, strip, NO_COLOR-aware gating |
| benchmark | benchmark runner with `Benchmark_*` functions |
| child | child process spawning with I/O control |
| codec | hex encoding/decoding, Lua serialization |
| compress | zlib compression/decompression |
| doc | extract docs from source and query the embedded documentation index |
| embed | create custom executables with embedded files |
| env | environment variable get/set/unset |
| envd | load environment variables from embedded env.d directory |
| example | example runner with `Example_*` functions |
| fetch | HTTP client with retry support |
| flags | declarative command-line flag parsing with generated --help |
| format | Teal/Lua code formatter |
| fs | filesystem: paths, stat, walk, read/write, mkdir, symlink, tmp |
| fuzzy | fuzzy string matching (Levenshtein distance) |
| getopt | command-line option parsing (short + long opts) |
| hash | SHA-256 digest and Argon2 password hashing |
| html | HTML escaping |
| fd | file descriptor I/O: open/wrap handles, pipes |
| ip | IP address parsing, formatting, classification |
| json | JSON encode/decode |
| log | leveled logging to stderr with key=value fields |
| net | TCP/UDP/Unix sockets |
| poll | poll(2) wrapper for I/O multiplexing |
| proc | current process: pid, exec, resource usage |
| rand | cryptographic random bytes |
| re | POSIX extended regular expressions |
| sandbox | one-call fail-closed facade over pledge/unveil/landlock (fs + sys policy) |
| pledge | restrict system calls (OpenBSD, Linux) |
| unveil | restrict filesystem visibility (OpenBSD, or Linux via landlock) |
| landlock | Linux >=5.13 self-restricting filesystem sandbox |
| quicksand | Linux namespace + allowlist proxy box primitives and declarative `Box` builder |
| shm | shared memory with atomic ops and futexes |
| signal | signal handling, timers, sigsets |
| sqlite | SQLite with ergonomic query/exec/transaction API |
| sse | Server-Sent Events parser |
| string | trim, split, capitalize, starts_with, etc. |
| sys | OS/architecture detection, sysconf (nproc, page size), uname |
| syslog | system logging |
| table | deep copy/merge/equality and map/filter/reduce for tables |
| teal | Teal compilation and type checking |
| testrun | test execution and reporting |
| time | timestamps, sleep, clock, datetime |
| tty | terminal detection, window size, termios |
| url | URL encoding, parsing, escaping |
| user | user/group identity |
| uuid | UUIDv4 and UUIDv7 generation |
| zip | ZIP archive reading and writing |

## Testing

```bash
bin/make test                 # all tests
bin/make coverage             # tests with line coverage + ratchet vs lib/cosmic/coverage/baseline.txt
bin/make coverage-baseline    # rewrite the committed coverage ratchet floor
bin/make test only=sqlite     # filter by pattern
bin/make example              # run Example_* functions
bin/make benchmark            # run Benchmark_* functions
```

test files use a simple assertion pattern:
```teal
local function test_something()
  local result = module.do_thing()
  assert(result == expected, "got: " .. tostring(result))
end
test_something()
```

each test gets its own temp directory via `TEST_TMPDIR`.

## Performance

`lib/perf` holds the benchmark harness: end-to-end scenarios (JSON, SQLite,
HTTP, fs, crypto/codecs, binary startup) with per-scenario functional
checks, a JSON results format, and a noise-aware baseline comparison gate.

```bash
bin/make perf                 # run scenarios, write o/perf/current.json
bin/make perf-baseline        # snapshot baseline before optimizing
bin/make perf-compare         # re-run and fail on regression vs baseline
bin/make perf-selfcheck       # A/A control: same binary vs itself = noise floor
bin/make perf-bin COSMO_LUA=… # wrap a local cosmopolitan lua for PERF_BIN
```

all performance work follows the loop in `lib/perf/OPTIMIZE.md`: baseline →
hypothesis → change → `bin/make ci` (correctness/style gate) →
`bin/make perf-compare` (regression gate) → keep or revert. never weaken a
scenario or its check to make numbers pass; never commit `o/perf/*.json`.

the manual is split so no chapter fights the 500-line cap:
`lib/perf/optimize/finding.md` (spotting cosmic-layer wins),
`lib/perf/optimize/cosmopolitan.md` (optimizing the C layer against a
local whilp/cosmopolitan build — no release needed to measure), and
`lib/perf/optimize/measurement.md` (noise discipline). the hypothesis
backlog is GitHub issues labeled `perf` (whilp/cosmic for cosmic-layer
work, whilp/cosmopolitan for the C layer); find work with
`gh issue list --label perf --state open`.

## CI

- **pr.yml**: runs `make ci` (format + teal + test + example + lint + coverage ratchet) on push/PR to main
- **docs.yml**: publishes generated docs to `docs` branch on push to main
- **release.yml**: daily release build producing `cosmic-lua` and `cosmic-lua-debug`
