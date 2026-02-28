# Makefile Patterns

cosmic uses GNU Make with a module system defined in `cook.mk` files. the build driver is `bin/make` (a shell script that downloads landlock-make on first run). all build artifacts go to `o/`.

## Common Targets

```bash
bin/make help             # show all targets with descriptions
bin/make build            # build the cosmic binary -> o/bin/cosmic
bin/make test             # run all tests (incremental, parallel)
bin/make teal             # type check all files (strict mode)
bin/make format           # check code formatting
bin/make example          # run Example_* functions
bin/make benchmark        # run Benchmark_* functions
bin/make lint             # check file length limits
bin/make ci               # full pipeline: format + teal + test + example + lint
bin/make clean            # remove o/ build directory
bin/make docs             # generate markdown docs from source
bin/make bootstrap        # download bootstrap cosmic binary
```

## Filtering

use `only=` to filter targets by pattern:

```bash
bin/make test only=json       # run only tests matching "json"
bin/make teal only=sqlite     # type check only files matching "sqlite"
bin/make format only=fs       # check formatting only for "fs" files
```

## Module Declarations

each directory declares a module via a `cook.mk` file:

```makefile
modules += mymod
mymod_srcs := $(wildcard lib/mymod/*.tl)
mymod_tests := $(filter %_test.tl,$(mymod_srcs))
mymod_examples := $(filter %_example.tl,$(mymod_srcs))
mymod_tl := $(filter-out $(mymod_tests) $(mymod_examples),$(mymod_srcs))
mymod_lua := $(patsubst %.tl,$(o)/%.lua,$(mymod_tl))
mymod_files := $(mymod_lua)
mymod_deps := cosmos tl
mymod_lua_dirs := lib/mymod
```

key variables:
- `_srcs`: all source files
- `_tl`: source files (excluding tests and examples)
- `_tests`: test files (`*_test.tl`)
- `_examples`: example files (`*_example.tl`)
- `_files`: build outputs
- `_deps`: module dependencies
- `_lua_dirs`: directories added to LUA_PATH

## Compilation Pipeline

```makefile
# Teal -> Lua (incremental: skip if unchanged)
$(o)/%.lua: %.tl $(types_files) $(tl_files) $(bootstrap_files)
	@$(bootstrap_cosmic) --compile $< > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi
```

## Test Rules

```makefile
# run test, capture stdout/stderr/exit-code
$(o)/%.tl.test.got: $(o)/%.lua $(test_files) $(o)/bin/cosmic | $(cosmic_bin)
	@cosmic --test $(basename $@) $(cosmic_bin) $<
```

each test gets:
- `TEST_TMPDIR` — isolated temp directory (cleaned after test)
- `TEST_BIN` — path to `o/bin/`
- `TEST_O` — build output directory
- `LUA_PATH` — aggregated from all modules' `lua_dirs`
- `NO_COLOR=1` — disable colored output

## Type Check Rules

```makefile
$(o)/%.teal.got: $(o)/% $(cosmic_bin)
	-@$(cosmic_bin) --check-types $< > $(basename $@).out 2> $(basename $@).err; echo $$? > $@
```

## Format Check Rules

```makefile
$(o)/%.format.got: $(o)/% $(cosmic_bin)
	-@$(cosmic_bin) --check-format $< > $(basename $@).out 2> $(basename $@).err; echo $$? > $@
```

## CI Pipeline

`bin/make ci` runs all stages in parallel with `--keep-going`:

1. **format** — check code formatting
2. **teal** — type check all files (strict)
3. **test** — run all tests
4. **example** — run and validate examples
5. **lint** — check file length limits

each stage produces a summary file. if any stage has failures, CI exits nonzero.

## Sandboxing

when using `bin/make` (landlock-make), each rule gets pledge/unveil constraints:

```makefile
# only allow read access to sources, read-write to output
$(o)/%.tl.test.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%.tl.test.got: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwc:$(o) rwc:$(TMP)
```

## Versioned Dependencies

third-party dependencies use a fetch/stage pipeline:

```
version.lua -> .versioned (symlink) -> .fetched (download) -> .staged (extract)
```

each 3p module has `version.lua` (version, SHA, URL) and `cook.mk`.
