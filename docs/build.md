# Build System

## Quick Reference

```bash
bin/make help           # list all targets with descriptions
bin/make build          # build cosmic binary → o/bin/cosmic
bin/make test           # run all tests (incremental)
bin/make teal           # type check all files
bin/make format         # check formatting
bin/make ci             # full CI pipeline
bin/make clean          # remove o/
```

## How It Works

the build uses GNU Make with a module system. each directory provides a `cook.mk` that declares its module.

### Module Declarations

a module declares these variables:

```makefile
modules += mymod                          # register module
mymod_tl := $(wildcard lib/mymod/*.tl)    # source files
mymod_tests := $(filter %_test.tl,...)    # test files
mymod_files := $(o)/bin/mymod             # build outputs
mymod_deps := cosmos tl                   # module dependencies
```

the top-level Makefile aggregates all modules and derives:
- `all_tl` / `all_lua`: all Teal sources and their compiled Lua
- `all_tests` / `all_tested`: test files and their results
- dependency edges: a module's files depend on its deps' files/staged outputs

### Compilation

Teal files compile to Lua via the bootstrap cosmic binary:

```makefile
$(o)/%.lua: %.tl $(types_files) $(tl_files) $(bootstrap_files)
    @$(bootstrap_cosmic) --compile $< > $@
```

### Versioned Dependencies (3p/)

third-party modules use a three-stage pipeline:

```
version.lua → .versioned → .fetched → .staged
```

1. **version.lua**: declares version string, SHA256, and download URLs
2. **fetch**: `build-fetch.lua` downloads the archive, verifies the hash
3. **stage**: `build-stage.lua` extracts to `o/staged/<module>/<ver>-<sha>/`

symlinks connect `o/<module>/.staged` to the extracted directory.

### Test Execution

```makefile
$(o)/%.tl.test.got: $(o)/%.lua ...
    @TEST_TMPDIR=$$(mktemp -d) $< > $(basename $@).out 2> $(basename $@).err
    @echo $$? > $@
```

each test:
- runs as a standalone script (compiled `.lua` with shebang)
- gets its own `TEST_TMPDIR`
- captures stdout to `.out`, stderr to `.err`, exit code to `.got`
- `reporter.tl` aggregates `.got` files into a summary

### Sandboxing

with landlock-make (`bin/make`), each rule declares security constraints:

```makefile
$(o)/%.tl.test.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%.tl.test.got: .UNVEIL = rx:$(o)/bootstrap r:lib rwc:$(o) rwc:$(TMP)
```

- `.PLEDGE` restricts system calls (OpenBSD pledge semantics)
- `.UNVEIL` restricts filesystem paths and permissions

### Building the cosmic Binary

the cosmic binary is assembled in `lib/cosmic/cook.mk`:

1. compile all `cosmic.*` modules to `.lua`
2. copy modules, tl.lua, type definitions, and doc index into a staging area
3. copy the cosmos lua binary as the base executable
4. append the staging area as a zip archive
5. append `main.lua` and `.args` to the zip

the result is a single executable with all modules accessible at `/zip/.lua/`.

## CI Pipeline

`make ci` runs four stages with `--keep-going`:

1. **format**: check all files with `cosmic --check-format`
2. **teal**: type check all files with `cosmic --check-types`
3. **test**: run all `*_test.tl` files
4. **example**: run all `Example_*` functions in `*_example.tl` files

failures in any stage are collected and reported at the end.

## Filtering

use `only=` to filter by pattern:

```bash
bin/make test only=sqlite     # only sqlite tests
bin/make teal only=cosmic     # only cosmic module type checks
bin/make files only=cosmic    # only build cosmic files
```

## Bootstrap Cycle

the bootstrap avoids circular dependency (need cosmic to compile cosmic):

1. a pre-built `cosmic` binary is downloaded to `o/bootstrap/cosmic`
2. it compiles all `.tl` → `.lua` and builds the new cosmic binary
3. `make stage1` copies the new binary over the bootstrap
4. `make stage2` (alias for `make ci`) re-checks everything with the refreshed bootstrap

the bootstrap URL is pinned in `cook.mk`.
