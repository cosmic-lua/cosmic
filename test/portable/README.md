# Portable artifact fixtures

## Layout

`lib.sh` is the shared shell library every script here sources: the
sha256sum/shasum fallback (`sha256_of`), the diagnostics-directory
validation (`require_diagnostics_dir`), a working-database snapshot and
integrity check (`snapshot_work_db`), the host-target lookup in
`targets.tsv` (`host_target_field`), the block-aligned manifest core-range
extraction recipe (`extract_core_range`), and the `timeout`/`gtimeout`
bound with its GitHub Actions fallback (`run_bounded`). `tool.tl` is the
matching Teal counterpart: one module, run as
`cosmic test/portable/tool.tl SUBCOMMAND ARGS...`, whose subcommands replace
what used to be over a dozen single-purpose scripts (writing a fixture
artifact, extracting a manifest entry, corrupting a core range, and so on).
`artifact_fixture.tl` is the small v1 artifact reader/writer-input library
both `tool.tl` and `build/artifact.tl` fixtures build on.

Three pairs of scripts each build one kind of fixture and then exercise it;
since they always work on the same fixture, each pair is one entry point
with `build`/`test` verbs:

- `launcher.sh build OUTPUT TARGET` / `launcher.sh test TEST_ARTIFACT [SOCKET_HELPER]`
- `product.sh build OUTPUT` / `product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]`
- `runtime.sh build OUTPUT [PREBUILT_PREFIX [WRITER PORTABLE_DATABASE]]` / `runtime.sh test RUNTIME_FIXTURE_DIRECTORY`

`format.sh`, `identity_test.sh`, and `self_rebuild.sh`
stay as their own entry points: each is called on its own, independent of
any sibling build step.

## What each one covers

`format.sh` is the cross-language format check: the production Teal writer
makes a prefix from `build.zig`'s generated records and real cores, and the
production C decoder (`format_test.c`, linked against `core/portable.c`)
validates it before a battery of focused malformed-field mutations is
tried against it.

`launcher.sh build` compiles one native contract payload per generated
target and writes one launcher fixture containing both a release prefix and
a test prefix with synchronization hooks compiled in. `launcher.sh test`
is the focused integration coverage for the production portable shell
launcher: cache leaf policy (mode, ownership, symlinks), repair of a
corrupted or malformed cached core, concurrent-publisher and
interruption races, caller descriptor preservation, descriptor exhaustion,
and payload exit/signal propagation. The generated launcher uses POSIX
shell builtins plus `uname`, `stat`, `id`, `mkdir`, `chmod`, `mktemp`, `dd`,
`head`, `ln`, `rm`, and either `sha256sum` or `shasum`. The directory
containing the cache leaf is the user's trust boundary; the launcher
rejects a linked leaf, an unexpected owner or mode, and unexpected entries,
and a warm launch still stats and hashes the complete cached core before
execution. `COSMIC_PORTABLE_CACHE` is the public cache setting; the
remaining `COSMIC_PORTABLE_*` fields are a reserved launcher-to-core
contract that startup requires complete, adopts, and clears before Lua
runs.

`product.sh build` makes the per-host provenance bundle from a booted
tree: it copies portable Cosmic, extracts its exact prefix and manifest
(`tool.tl product-extract`), and uses those same local portable bytes to
build the `hello` and `second` standalone fixtures. The bundle also
carries every generated release target's raw core; extraction checks that
each core occurs exactly once, at its manifest range, in Cosmic and both
applications. `product.sh test` verifies every recorded transported hash,
exact prefix reuse, the selected manifest range's length, digest, and raw
core bytes, and both applications; on the macOS host it also sends that
extracted range to strict `codesign` verification. Normal CI runs these checks
in independent x86 Linux, ARM Linux, and ARM macOS producers, plus an x86 Linux
producer whose product also runs under Alpine. The `provenance` job compares
the exact `cosmic` bytes all four attest they ran.

`runtime.sh build` and `runtime.sh test` cover real Cosmic cores end to end
against the runtime's host-independent projection. A fixture-only core
build contains a deterministic FIFO pause after descriptor validation and
before SQLite opens the main database; ordinary cores contain neither the
hook code nor its environment names. Atomic replacement and unlink at that
pause prove both VFS and the trusted `build.artifact` prefix capability
keep reading the retained artifact descriptor. `runtime.sh build` selects
one complete immutable file per fixture; writing that same inode in place
remains unsupported and is deliberately not presented as safe.

`runtime.sh build OUTPUT [PREBUILT_PREFIX [WRITER PORTABLE_DATABASE]]`
normally uses a booted checkout's `o/bin/cosmic` and `o/cosmic.db`. With no
prebuilt prefix it invokes `bin/zig build portable-fixture-cores` once in a
temporary directory, sharing one patched-vendor graph across the three
release cores, three fixture-hook cores, and the distinct sanitized core.
A supplied prefix must contain `targets.tsv`, release cores under
`core/<target>/cosmic-core`, hook cores under
`portable-fixture/core/<target>/cosmic-core`, and the checked core at
`portable-fixture/sanitized/cosmic-core`; every input is checked before
output is generated. The explicit four-argument form lets CI combine the
x86 producer's release/hooked cores and Cosmic/database with the checked
core the `sanitized` job already tested, without compiling that core a
second time.

`identity_test.sh` exercises the production retained-artifact route. It
builds two portable applications from the retained prefix, executes
canonical Linux application bytes unchanged on all three hosts, checks
logical executable paths, prefix reuse, suffix-only application edits, one
shared cache entry, unlink-after-startup builds, and rejection of a corrupt
nonselected core before an application is published. It also uses one work
database successively with real release and sanitized cores, a changed
runtime basis, an unchanged repeat, and an application-database-only
change: changed runtime contexts run, while unchanged and
application-only contexts stand. Normal CI runs that complete identity proof
independently on every native host. Mutable developer state remains local to
one runner; cross-platform support is established by executing and attesting
the same immutable product bytes in all supported platform environments.

`self_rebuild.sh` uses the same fixture-only startup pause to rename and
unlink the artifact after descriptor adoption. In each case a deterministic
Teal edit causes exactly one database-only rebuild and re-entry at the same
logical portable path. The rebuilt file keeps the retained prefix and cache
entry, and an ordinary environment value reaches the re-entered tests. A
subsequent core input edit is refused with the named `bin/zig build boot`
remedy and does not change the artifact.

The pinned CI driver owns full-suite execution, retained output, working
database snapshots, delayed boundaries, and artifact immutability checks.
It runs portable suites from a fresh tracked-source export and runs the same
product in an offline, unprivileged Alpine container. Its isolated project
and command contracts are documented in `test/ci/driver`.
