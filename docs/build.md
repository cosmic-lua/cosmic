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
$(o)/%.tl.test.got: .PLEDGE := stdio rpath wpath cpath proc exec
$(o)/%.tl.test.got: .UNVEIL := rx:$(o)/bootstrap r:lib rwc:$(o) rwc:$(TMP)
$(o)/%.lua: .ENV := LUA_PATH TREE_LUA_PATH TL_PATH LC_ALL TZ NO_COLOR
```

- `.PLEDGE` restricts system calls (OpenBSD pledge semantics)
- `.UNVEIL` restricts filesystem paths and permissions
- `.ENV` clamps the child environment to the named variables (#756 item
  5); the env-clamp fixture's canary probe gates it

these are **enforced, not documented intent** (#729). every rule family
CI exercises sets `.SANDBOXED := 1` — compile (#739),
fetch/stage/lint/reporter (#740), teal/format (#742), tests (#743),
examples (#745) — so an undeclared read or write in one of those
recipes fails on a Landlock host. `unveil()` no-ops where Landlock is
unavailable, which is what the `sandbox-canary` probe (#716/#724)
exists to detect.

three families deliberately opt out, each with its reason recorded at
the rule: `version.lua` (reads `.git`, and its fallback would silently
mint an unversioned artifact), the quicksand namespace tests and
examples (`unshare` has no pledge promise — the `enforce` lane covers
them instead), and the benchmark family, which keeps its annotations
without enforcement because no CI lane runs benchmarks. enforcing
grants that nothing exercises is not a falsifiable gate; that family
flips when a lane runs it.

losing enforcement is silent — drop a `.SANDBOXED := 1` and every grant
set is still a superset of what the recipe needs, so nothing fails and
CI stays green. the `.SANDBOXED` ratchet in
`lib/build/makefile_ratchet_test.tl` enumerates the enforced set and
the exceptions and fails in both directions, which is the only thing
that notices.

recipes are shell-free by default (#756 item 2): the global `SHELL` is
poisoned, recipes are single argv lines run via make's direct-exec
path, and the real shell is a per-rule `private` exception. The
makefile ratchet tests enumerate the exception set, the
`$(unveil_hostx)` carriers, and statically scan recipe text for shell
syntax — all three fail when a set grows without a declared reason.

most grants are not written by hand at all: landlock-make derives them
from the declared graph (prerequisites readable, the target's directory
writable, plus the global base), so a rule declares only genuinely-extra
paths. that derivation is gated upstream in
`test/tool/build/make_sandbox_test.sh` (whilp/cosmopolitan#210).

`bin/make audit-unveil` shrinks the hand-written remainder with evidence
instead of guesswork (#756 item 4): it rebuilds a representative target
per enforced family with one grant entry withheld, and reports the
entries that rule did not need. two limits are structural — it needs
Landlock (it refuses to run without it, since every verdict would read
UNUSED for the wrong reason), and it only reaches grants composed from a
shared variable, not per-rule literals. its verdicts are scoped to the
targets it audited; a rule outside that list may still need an entry it
reports.

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

the build's trust root — what `bin/make` fetches, what stays outside
the root, and the settled decision that pinned make is permanent — is
recorded in [decisions.md](decisions.md) (D13, D14).
