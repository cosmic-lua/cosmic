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
work.mk                autonomous agent work loop (PDCA cycle)
lib/
  cook.mk              aggregates lib/* modules
  cosmic/              standard library modules (*.tl)
    cook.mk            builds the cosmic binary
    CLAUDE.md          coding conventions for cosmic modules
    init.tl            entry point: cosmic.main()
    main.tl            CLI dispatcher (--compile, --docs, --test, etc.)
    *.tl               library modules
    *_test.tl          tests
    *_example.tl       runnable examples
  build/               build infrastructure (fetch, stage, reporter)
  docs/                doc publishing
  types/               .d.tl type definitions for cosmo.* bindings
  work/                work pipeline script (labels, issue pick, act)
3p/
  cosmos/              Cosmopolitan Lua binary + zip tool
  tl/                  Teal compiler
  teal-types/          community type definitions
  ah/                  agent harness binary
bin/
  make                 bootstrap script that downloads landlock-make
  cosmo-make           landlock-make binary (gitignored, downloaded)
.github/workflows/
  pr.yml               CI on push/PR (make ci)
  work.yml             autonomous work loop (every 3h or manual)
  docs.yml             publish docs on push to main
  release.yml          daily release build
.claude/skills/        agent skills (project board, friction logs)
```

## Language and Conventions

- **source language**: Teal (`.tl` files) — typed Lua that compiles to Lua 5.4
- **error handling**: return `value, string` (nil + error message on failure). never throw from library code. see `lib/cosmic/CLAUDE.md` for the full pattern guide.
- **doc comments**: `---` prefix with `@param` and `@return` tags
- **naming**: `snake_case` for functions and variables. `PascalCase` for record types.
- **formatting**: 2-space indent, LF line endings, enforced by `cosmic --check-format`
- **tests**: `*_test.tl` files alongside source, run via `make test`
- **examples**: `*_example.tl` files with `Example_*` functions, run via `make example`

## Build System

the build uses GNU Make with a module system defined in `cook.mk` files.

```bash
bin/make help           # show all targets
bin/make build          # build cosmic binary
bin/make test           # run all tests (incremental)
bin/make teal           # type check all files
bin/make format         # check formatting
bin/make ci             # full CI: format + teal + test + example
bin/make docs           # generate markdown docs from source
bin/make clean          # remove build artifacts
```

key concepts:
- **modules**: each directory declares a module via `cook.mk` with `_tl`, `_tests`, `_files`, `_deps`
- **versioned deps**: 3p modules use `version.lua` → fetch → stage pipeline
- **bootstrap**: a pre-built cosmic binary bootstraps compilation of `.tl` → `.lua`
- **sandboxing**: landlock-make applies pledge/unveil per-rule for build isolation
- **output directory**: all build artifacts go to `o/`

## cosmic Binary

the cosmic binary is an executable zip. it embeds:
- compiled `.lua` modules in `.lua/cosmic/`
- Teal compiler in `.lua/tl.lua`
- type definitions in `.lua/types/` and `.lua/teal-types/`
- doc index in `.docs/index.lua`
- entry point: `/zip/main.lua` (compiled from `lib/cosmic/main.tl`)

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
| benchmark | benchmark runner with `Benchmark_*` functions |
| child | child process spawning with I/O control |
| codec | hex encoding/decoding, Lua serialization |
| compress | zlib compression/decompression |
| doc | extract docs from Teal source files |
| docs | query embedded documentation index |
| embed | create custom executables with embedded files |
| env | environment variable get/set/unset |
| example | example runner with `Example_*` functions |
| fetch | HTTP client with retry support |
| format | Teal/Lua code formatter |
| fs | filesystem: paths, stat, walk, mkdir, symlink, tmp |
| fuzzy | fuzzy string matching (Levenshtein distance) |
| getopt | command-line option parsing (short + long opts) |
| hash | SHA-256 digest and Argon2 password hashing |
| html | HTML escaping |
| io | file descriptor I/O, pipes, slurp/spit |
| ip | IP address parsing, formatting, classification |
| json | JSON encode/decode |
| net | TCP/UDP/Unix sockets |
| poll | poll(2) wrapper for I/O multiplexing |
| proc | current process: pid, exec, resource usage |
| rand | cryptographic random bytes |
| re | POSIX extended regular expressions |
| sandbox | pledge and unveil for security sandboxing |
| shm | shared memory with atomic ops and futexes |
| signal | signal handling, timers, sigsets |
| sqlite | SQLite with ergonomic query/exec/transaction API |
| sse | Server-Sent Events parser |
| string | trim, split, capitalize, starts_with, etc. |
| sys | OS/architecture detection |
| syslog | system logging |
| teal | Teal compilation and type checking |
| testrun | test execution and reporting |
| time | timestamps, sleep, clock, datetime |
| tty | terminal detection, window size, termios |
| url | URL encoding, parsing, escaping |
| user | user/group identity |
| uuid | UUIDv4 and UUIDv7 generation |
| zip | ZIP archive reading and writing |

## Work Loop

the autonomous work loop (`work.mk`) implements a PDCA cycle:

1. **preflight**: ensure labels, check PR limits, fetch issues
2. **pick**: select highest-priority issue
3. **plan**: agent writes `plan.md` from issue context
4. **do**: agent implements changes on a branch
5. **push**: push branch with `--force-with-lease`
6. **check**: agent reviews diff, writes verdict + actions
7. **act**: execute actions (open PR, post comment, etc.)

convergence: if check returns "needs-fixes", the loop retries up to 3 times. the agent harness (`ah`) provides sandboxed execution with skills for plan/do/check.

## Testing

```bash
bin/make test                 # all tests
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

## CI

- **pr.yml**: runs `make ci` (format + teal + test + example) on push/PR to main
- **work.yml**: runs autonomous work loop every 3 hours
- **docs.yml**: publishes generated docs to `docs` branch on push to main
- **release.yml**: daily release build producing `cosmic-lua` and `cosmic-lua-debug`
