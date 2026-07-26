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

Teal files compile to Lua through the pinned bootstrap's own shell-free
recipe surface (`cosmic --build`, #732/#756 item 3) — no redirect, no host
`cat`/`cmp`/`mv`:

```makefile
$(o)/%.lua: %.tl $(types_files) $(bootstrap_files)
    @$(bootstrap_cosmic) --build compile $(bootstrap_cosmic) $< $@ $(include_dir_flags)
```

compiles are **always** strict (`--compile-strict`: type check, then
generate from that same checked AST) with `LUA_PATH=";;"`, which is what
makes the output independent of parallel build order (#733). there is no
flag to select: #776 retired both the probe and the stamp file the driver
used to read, along with the non-strict fallback that could degrade
silently.

### Versioned Dependencies (3p/)

third-party modules use a three-stage pipeline:

```
*.pin.tl → .versioned → .fetched → .staged
```

1. **`*.pin.tl`**: a pin — one `return { … }` of literals declaring the
   version, digest and url. It is READ as data by `cosmic.literal`,
   never executed, so the file that says what to fetch cannot do
   anything itself. Same reader `cosmic --make fetch` uses, so the
   grammar is enforced identically from both sides.
2. **fetch**: `build-fetch.lua` downloads the archive, verifies the hash
3. **stage**: `build-stage.lua` extracts to `o/staged/<module>/<ver>-<sha>/`

`cosmic --make fetch` resolves the same pins through its own path,
landing bytes under `o/` mirroring the pin's position
(`3p/tl/tl.pin.tl` → `o/3p/tl/…`). Until the Makefile retires, both
readers are live over the same committed files.

symlinks connect `o/<module>/.staged` to the extracted directory.

### Test Execution

```makefile
$(o)/%.tl.test.got: $(o)/%.lua $(cosmic_bin) $(ape_loader)
    @$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<
```

`cosmic --test` owns the capture — the recipe is a single argv line with
no shell, no `mktemp`, and no redirects. each test:
- runs as a standalone script (compiled `.lua` with shebang)
- gets its own `TEST_TMPDIR`, created and cleaned up by the runner
- captures stdout to `.out`, stderr to `.err`, exit code to `.got`
- is aggregated into a summary: `cosmic --report` for the test, coverage,
  and enforce lanes; `_build/reporter.tl --out` for teal, format,
  lint, example, and benchmark

type and format checks follow the same shape but read the **source**
directly (`$(o)/%.teal.got: %`), as lint always has — there is no copy of
the tree under `o/` (#775).

#### test lanes

the same tests run in three lanes, each in its own output tree so one
never invalidates another:

| lane | targets | what it adds |
|------|---------|--------------|
| plain | `o/<src>.test.got` | — |
| coverage | `o/coverage/<src>.test.got` | `COSMIC_COVERAGE=1`, ratcheted against the committed baseline |
| enforce | `o/enforce/<src>.test.got` | `COSMIC_ENFORCE=1`, no outer sandbox; a fixed three-file list |

a per-test exception applies to every lane, so modules declare the test
source once and expand it with `$(call test_got,<src>...)` (#778):

```makefile
$(call test_got,_build/help_test.tl): .UNVEIL := $(unveil_test) r:Makefile
```

**the lane patterns nest.** `o/coverage/x.tl.test.got` and
`o/enforce/x.tl.test.got` both match the plain `$(o)/%.tl.test.got`
pattern (with stems `coverage/x` and `enforce/x`), so they **inherit**
its pattern-specific variables — more specific patterns win per-variable,
but anything the plain pattern sets and they do not reaches them. two
consequences:

- the `enforce` lane must **explicitly empty** `.PLEDGE`/`.UNVEIL` and set
  `.SANDBOXED := 0`; simply omitting them would inherit the plain lane's
  sandbox, which is precisely what that lane exists to run without.
- widening a grant on the plain pattern silently widens all three lanes.
  add it to the specific lane, or to the specific test via `test_got`.

### Sandboxing

with landlock-make (`bin/make`), each rule declares security constraints:

```makefile
$(o)/%.tl.test.got: .PLEDGE := stdio rpath wpath cpath proc exec
$(o)/%.tl.test.got: .UNVEIL := rx:$(o)/bootstrap r:lib rwc:$(o) rwc:$(TMP)
$(o)/%.lua: .ENV := LUA_PATH TL_PATH LC_ALL TZ NO_COLOR
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
the rule: the version stamp (reads `.git`, and its fallback would silently
mint an unversioned artifact), the quicksand namespace tests and
examples (`unshare` has no pledge promise — the `enforce` lane covers
them instead), and the benchmark family, which keeps its annotations
without enforcement because no CI lane runs benchmarks. enforcing
grants that nothing exercises is not a falsifiable gate; that family
flips when a lane runs it.

losing enforcement is silent — drop a `.SANDBOXED := 1` and every grant
set is still a superset of what the recipe needs, so nothing fails and
CI stays green. the `.SANDBOXED` ratchet in
`_build/makefile_ratchet_test.tl` enumerates the enforced set and
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

#### what each family's sandbox actually buys

"enforced" does not mean "equally confined" — the grant sets differ by
an order of magnitude, and it is worth knowing which guarantee you are
relying on (#781):

| family | grants beyond the base | what is actually denied |
|---|---|---|
| compile (`%.lua`) | `r:tlconfig.lua` + device nodes | everything else: no host exec, no network, no writes outside the target's directory |
| teal / format | `r:tlconfig.lua`, `rwc:$(TMP)`, devices | same — **no** `$(unveil_hostx)` |
| lint | `rwc:$(TMP)`, devices | same |
| fetch | archive cache, resolv/hosts/ssl, `inet dns` | writes outside the fetch cache; the only family with network |
| stage | fetch cache read, staged tree write | network, host exec |
| test / example / benchmark | `rwcx:$(o)`, `rwcx:$(TMP)`, **`$(unveil_hostx)`** | writes outside `o/` and `$(TMP)` — notably the source tree (`lib`, `3p` are `r:`) and `$HOME` |

the first five are genuinely tight: an undeclared read fails. the test
lanes are not — `$(unveil_hostx)` is `rx:` over `/usr`, `/bin`, `/lib`,
`/lib64`, `/proc` plus `r:/etc`, because tests legitimately exec host
tools. what the test-lane sandbox buys is narrower and still worth
having: **a test cannot write outside `o/` and `$(TMP)`**, so it cannot
scribble on the source tree or your home directory. read "tests are
sandboxed" as that, not as the compile family's guarantee.

this is why the `$(unveil_hostx)` ratchet earns its keep. its value is
not in cataloguing the loose lanes — it is that `rx:/usr` appearing on
a *tight* family (a compile, a fetch, a lint) fails the ratchet loudly
instead of silently widening the build's best-confined rules.

### Building the cosmic Binary

the cosmic binary is assembled in `cosmic/cook.mk`:

1. compile all `cosmic.*` modules to `.lua`
2. copy modules, tl.lua, type definitions, and doc index into a staging area
3. copy the cosmos lua binary as the base executable
4. append the staging area as a zip archive
5. append `main.lua` and `.args` to the zip

the result is a single executable with all modules accessible at the zip root: `/zip/cosmic/fs.lua` is `require("cosmic.fs")`.

## CI Pipeline

`make ci` runs six stages with `--keep-going`:

1. **format**: check all files with `cosmic --check-format`
2. **teal**: type check all files with `cosmic --check-types`
3. **test**: run all `*_test.tl` files
4. **example**: run all `Example_*` functions in `*_example.tl` files
5. **lint**: file length, cast justifications, and shared style checks on
   every tracked file
6. **coverage**: the tests again in a separate output tree with collection
   on, ratcheted against `.coverage`

each stage gets a `ci-ok-<stage>` exit marker, made only after its entire
subtree succeeded. grading reads the marker as well as the summary text,
so a recipe that fails *after* writing a clean summary still fails the
stage (#714). the run ends with a `ci: PASS` / `ci: FAIL (stages)` line.

## Filtering

use `only=` to filter by pattern:

```bash
bin/make test only=sqlite     # only sqlite tests
bin/make teal only=cosmic     # only cosmic module type checks
bin/make files only=cosmic    # only build cosmic files
```

## Bootstrap Cycle

the bootstrap avoids circular dependency (need cosmic to compile cosmic):

1. `bin/make` downloads a pre-built `cosmic` to `o/bootstrap/cosmic`,
   verifies it against the sha in `cook.mk`, and assimilates it to a
   native ELF. it is the *sole* provisioner — the Makefile's rule only
   errors, and a pin bump re-downloads via the `.pin` stamp.
2. it compiles all `.tl` → `.lua` and builds the new cosmic binary.

the bootstrap URL and sha are pinned in `cook.mk` and bumped **by hand**;
no workflow refreshes them, and nothing verifies that the tree can rebuild
itself under a binary it just produced. `make stage1`/`stage2` used to
gesture at that check but no lane ever ran them, so they were removed
(#774) rather than left as a gate that never fires. if the self-host
property is worth guaranteeing, it wants a CI lane, not a manual target.

the build's trust root — what `bin/make` fetches, what stays outside
the root, and the settled decision that pinned make is permanent — is
recorded in [decisions/](decisions/) (D13, D14).
