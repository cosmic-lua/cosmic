# Architecture

## Overview

cosmic is a single-binary Lua distribution. it compiles Teal source into Lua, bundles compiled modules with a Cosmopolitan Libc runtime, and produces fat executables that run on six operating systems without modification.

## Key Design Decisions

### Executable ZIP Format

the cosmic binary is an executable zip — a native ELF/Mach-O/PE binary with a ZIP archive appended. Cosmopolitan Libc maps the zip contents to `/zip/` at runtime. this enables:

- single-file distribution (no installation, no runtime dependencies)
- embedding arbitrary files alongside Lua modules
- custom executables via `cosmic --embed`

the entry point is `/zip/main.lua` (compiled from `lib/cosmic/main.tl`). the `.args` file provides default command-line arguments.

### Two-Layer Type System

the codebase has two layers of bindings:

1. **`cosmo.*`** — raw C bindings exposed by Cosmopolitan Libc. these are low-level and untyped from Teal's perspective. type definitions live in `lib/types/cosmo/*.d.tl`.

2. **`cosmic.*`** — ergonomic Teal wrappers that add type safety, error handling, and resource management. these are the public API.

users import `cosmic.*` modules. `cosmo.*` bindings are available but undocumented by default.

### Module Build Pipeline

```
.tl source → cosmic --compile → .lua → zip into binary
```

the bootstrap problem: compiling `.tl` requires a working cosmic binary. this is solved by checking in a pre-built bootstrap binary that gets refreshed during CI (`make stage1`).

dependency chain:
```
bootstrap cosmic (pre-built)
  → compiles build scripts (build-fetch.lua, build-stage.lua)
  → fetches/stages 3p deps (cosmos, tl)
  → compiles cosmic modules (.tl → .lua)
  → builds cosmic binary (link lua + zip modules)
  → stage1: refreshed bootstrap = new cosmic
  → stage2: type check + test with refreshed bootstrap
```

### Sandboxed Build

`bin/make` is the trust root: it fetches the sha-pinned bootstrap cosmic,
which extracts `make` from the sha-pinned cosmos.zip — two pinned
artifacts, one committed fetcher, no other host downloads (#756).

under landlock-make, each build rule declares its access:
- **pledge**: restricts available system calls (e.g., `stdio rpath`)
- **unveil**: restricts filesystem visibility (e.g., `r:lib rwc:o/`)
- **.ENV**: clamps the child environment to named variables

recipes are shell-free by default: `SHELL` is poisoned globally and a
recipe is a single argv line, with the real shell a per-rule exception.
makefile ratchet tests enumerate the exceptions and the host-exec
grants, and fail when either set grows (#756 item 2).

## Directory Structure

### `lib/cosmic/` — Standard Library

each module follows a consistent pattern:

```teal
--- Module description.
local cosmo = require("cosmo")      -- or cosmo.unix, etc.

-- Record types
local record MyRecord
  field: type
end

-- Functions with doc comments
--- Description.
--- @param x type explanation
--- @return type explanation
local function do_thing(x: type): result, string
  ...
end

-- Module interface record
local record Module
  do_thing: function(x: type): result, string
end

local M: Module = { do_thing = do_thing }
return M
```

### `lib/types/` — Type Definitions

`.d.tl` files declare types for `cosmo.*` modules. these are generated from Cosmopolitan's `definitions.lua` by `lib/types/gentype.tl` and checked into the repo.

### `lib/build/` — Build Infrastructure

- `build-fetch.tl`: download versioned dependencies from GitHub releases
- `build-stage.tl`: extract and prepare fetched archives
- `reporter.tl`: aggregate test/check results into summaries
- `make-help.tl`: parse Makefile comments for `make help`

### `3p/` — Third-Party Dependencies

each 3p module has:
- `version.lua`: declares version, SHA, and download URLs
- `cook.mk`: declares module variables for the build system

the fetch/stage pipeline handles downloading, verifying, and extracting.

## Error Handling

see `AGENTS.md` for the complete guide. summary:

| pattern | when to use |
|---------|-------------|
| `value, string` | most functions (nil + error on failure) |
| `boolean, string` | success/fail operations |
| Result record | complex operations (HTTP fetch) |
| just `value` | infallible operations (encoding, compression) |

consistency within a module matters more than which pattern is chosen.

## Testing Architecture

tests are `*_test.tl` files that run as standalone scripts. the Makefile:

1. compiles each `_test.tl` to `.lua`
2. runs it, capturing stdout/stderr/exit-code to `.out`/`.err`/`.got`
3. aggregates results via `reporter.tl` into a summary

each test gets an isolated `TEST_TMPDIR`. test dependencies are resolved automatically from module declarations.

examples (`*_example.tl`) contain `Example_*` functions with expected output in comments. `cosmic --check-examples` runs them and validates output.

benchmarks use `Benchmark_*` functions with iteration-based timing.

