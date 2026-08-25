# Architecture

cosmic is a single-binary Lua distribution. it compiles Teal source
into Lua, bundles the compiled modules with a Cosmopolitan Libc
runtime, and produces fat executables that run on six operating
systems without modification.

## Key Mechanisms

### Executable ZIP Format

the cosmic binary is an executable zip — a native ELF/Mach-O/PE binary
with a ZIP archive appended. Cosmopolitan Libc maps the zip contents
to `/zip/` at runtime. this enables:

- single-file distribution (no installation, no runtime dependencies)
- embedding arbitrary files alongside Lua modules
- custom executables via `cosmic --embed`

the entry point is `/zip/main.lua` (compiled from
`cmd/cosmic/main.tl`, the same `cmd/<name>/` position `--make` builds
every binary from). the `.args` file provides default command-line
arguments.

### Two-Layer Type System

the codebase has two layers of bindings:

1. **`cosmo.*`** — raw C bindings exposed by Cosmopolitan Libc. their
   type declarations are generated into `o/_types/types_gen/` by
   `_types/types_gen.tl`.
2. **`cosmic.*`** — ergonomic Teal wrappers that add type safety,
   error handling, and resource management. these are the public API.

user code imports `cosmic.*`; the raw bindings stay reachable, and
`cosmic --docs cosmo.<module>` serves their generated reference.

### Module Build Pipeline

```
.tl source → cosmic --compile → .lua → zip into binary
```

the bootstrap problem: compiling `.tl` requires a working cosmic
binary. a pre-built one is pinned by url + sha256 in `bin/cosmic.pin`
and fetched by `bin/cosmic`. the pin is bumped by hand; a release is
built in two generations so what ships is produced by the code it
contains (see [build.md](build.md)).

dependency chain:

```
pinned cosmic (url + sha256 in bin/cosmic.pin, fetched by bin/cosmic)
  → resolves *_pin.tl (cosmos, tl) into o/3p/
  → runs the payload generator, compiles .tl → .lua
  → embeds the payload onto the pinned runtime → o/bin/cosmic
```

### Sandboxed Build

`bin/cosmic` is the trust root: it fetches ONE sha-pinned cosmic and
execs it, and cosmic extracts its own build engine from its own zip —
one pin, one committed fetcher, no other host downloads.

each build rule's access is DERIVED from its recipe line rather than
declared, because the verb vocabulary is closed and every verb's
signature already says what it touches:

- **reads**: the paths the verb's signature names as inputs — for a
  test, its own compiled file plus the transitive import closure the
  graph computed
- **writes**: the one output the verb names, and nothing else
- **exec**: only bytes already under the build root; a bare `cc` is
  refused rather than resolved through `PATH`

the fence is on by default and `COSMIC_FENCE=0` opts out. on Linux it
is Landlock; elsewhere the grants are computed and cannot be enforced,
which is why CI asserts a real denial rather than trusting that the
mechanism ran.

there is no per-rule shell exception to enumerate: `SHELL` is cosmic,
a recipe line is argv from a closed verb vocabulary, and a
metacharacter is refused rather than interpreted.

## Directory Structure

### `cosmic/` — Standard Library

every module has the same shape: a `---` doc-comment header whose
first line is the module's description, record types for the values
it trades in, doc-commented functions, and an interface record
returned at the bottom naming exactly the public surface. the
quickstart guide builds one end to end (`cosmic --docs
guide.quickstart`).

### `_types/` — Type Definitions

`.d.tl` files declare types for `cosmo.*` modules. they are generated
from Cosmopolitan's `definitions.lua` by `_types/gentype.tl` into
`o/_types/types_gen/`, and are **not committed** — the build produces
them, so a `cosmo.*` change shows up as the pin bump that caused it.
the cost: a fresh clone cannot resolve `cosmo.*` until it has fetched
and built once, and an editor needs that directory on its include
path.

### `_build/` — Ratchets

ratchets over what the repo ships and derives. each ratcheted surface
pairs a measurement with a committed floor and a test that fails when
the two disagree — among them the derived regions of committed docs,
the shipped make guide against `_make/`, the public module surface,
the `as`-cast count, tree size, and the GitHub workflow definitions.
`_build/ratchet.tl` is the shared reader they stand on: it parses a
committed document's markdown tables as rows.

### `3p/` — Third-Party Dependencies

each 3p module is one file:

- `*_pin.tl`: a pin — one `return { … }` of literals declaring the
  version, digest and url, read as data and never executed

`--make fetch` downloads it, verifies the digest, and unpacks beside
the pin. the marker is the whole registration; nothing else declares
it.

## Error Handling

the type must admit failure, and library code never throws —
`cosmic.check` (tests and examples only) is the one exemption:

| shape | when |
|---------|-------------|
| `T \| nil, string` | fallible value: callers narrow before use |
| `boolean, string` | fallible effect: nothing to return |
| own error record in slot 2 | failures with structure: `fetch.fetch` returns `Response \| nil, fetch.Error`; branch on `err.kind` |
| bare value | infallible: encoding, compression, escaping |

the worked doctrine with runnable examples is
[stdlib.md](stdlib.md) and `cosmic --examples errors`. consistency
within a module matters more than which pattern is chosen.

## Testing Architecture

tests are `*_test.tl` files that run as standalone scripts. `--make
test`:

1. builds the project's binaries and puts them on the child `PATH`,
   so a test can spawn the binary under test (`TEST_BIN` names its
   directory)
2. compiles each `_test.tl` to `.lua`
3. runs it, capturing stdout/stderr/exit-code to `.out`/`.err`/`.got`
4. aggregates the results into a summary

each test gets an isolated `TEST_TMPDIR`. a test's dependencies are
its own import closure, taken from the model — nothing is declared.

examples (`*_example.tl`) contain `Example_*` functions with expected
output in comments. `cosmic --check example` runs them and validates
output.

benchmarks use `Benchmark_*` functions with iteration-based timing.
