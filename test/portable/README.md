# Portable artifact fixtures

## Layout

`tool.tl` provides subcommands for writing fixture artifacts, extracting
manifest entries, corrupting core ranges, and related operations. Run it as
`cosmic test/portable/tool.tl SUBCOMMAND ARGS...`. `artifact_fixture.tl` is
the reusable v1 artifact reader and writer-input helper used by `tool.tl` and
the `build/artifact.tl` fixtures.

Product assembly, transport validation, the cross-language format contract,
launcher construction and regression, runtime construction and regression,
self-rebuild, and identity assertions are defined in `ci/fixtures`. The pinned
CI helpers in `ci/cosmic_ci` assemble and run them in isolated fixture
projects.

## What each one covers

The driver's `format_test.tl` is the cross-language format check: the
production Teal writer makes a prefix from `build.zig`'s generated records and
real cores, and the production C decoder (`format_test.c`, linked against
`core/portable.c`) validates it before a battery of focused malformed-field
mutations is tried against it.

The driver's `launcher_setup.tl` compiles one native contract payload per generated
target and writes one launcher fixture containing both a release prefix and
a test prefix with synchronization hooks compiled in. `launcher_test.tl`
is the focused integration coverage for the production portable shell
launcher: cache leaf policy (mode, ownership, symlinks), repair of a
corrupted or malformed cached core, concurrent-publisher and
interruption races, caller descriptor preservation, descriptor exhaustion,
and payload exit/signal propagation. The generated launcher uses POSIX
shell builtins plus `uname`, `stat`, `id`, `mkdir`, `chmod`, `mktemp`, `dd`,
`head`, `ln`, `rm`, and either `sha256sum` or `shasum`. The directory
containing the cache leaf is the user's trust boundary; the launcher
rejects a linked leaf, an unexpected owner or mode, and unexpected entries,
a warm launch stats the cached core and hashes it unless startup's verified
stamp still holds for it. `COSMIC_PORTABLE_CACHE` is the public cache setting; the
remaining `COSMIC_PORTABLE_*` fields are a reserved launcher-to-core
contract that startup requires complete, adopts, and clears before Lua
runs.

The driver's `product_setup.tl` makes the per-host provenance bundle
from a booted tree: it copies portable Cosmic, extracts its exact prefix and
manifest (`tool.tl product-extract`), and uses those same local portable bytes
to build the `hello` and `second` standalone fixtures. The bundle also carries
every generated release target's raw core; extraction checks that each core
occurs exactly once, at its manifest range, in Cosmic and both applications.
`product_test.tl` verifies every recorded transported hash, exact prefix
reuse, the selected manifest range's length, digest, and raw core bytes, and
both applications; on the macOS host it also sends that extracted range to
strict `codesign` verification. Normal CI runs these checks in independent x86
Linux, ARM Linux, ARM macOS, and Alpine x86 Linux producers. The `provenance`
job compares the exact `cosmic` bytes all four attest they ran.

The driver's `runtime_setup.tl` assembles the runtime fixture
directory (`COSMIC_FIXTURE_RUNTIME`) from a booted checkout's prebuilt cores,
portable writer, and portable database, which `RuntimeSetup.build` takes as
arguments: it writes the
`runtime.release`/`.old`/`.new`/`.basis`/`.missing`/`.sanitized`/
`.incompatible` complete artifacts and one `runtime.corrupt-<target>` file
per generated target, each with its retained-prefix hash and length
derived alongside it. The fixture-hook cores it copies in
(`portable-fixture/core/<target>/cosmic-core`) contain a deterministic FIFO
pause after descriptor validation and before SQLite opens the main
database; ordinary release cores contain neither the hook code nor its
environment names. It also derives a fourth, launcher-unreachable sanitized
manifest entry that binds the real host sanitized core, and copies
`probe.tl`, `runtime_test.tl`, and `hello_main.tl` alongside the
generated `targets.tsv` for the fixtures that follow it.

`runtime_test.tl` covers real Cosmic cores end to end against the
runtime's host-independent projection: the nine-phase startup-diagnostic
sequence; logical-path and occupied-descriptor reuse across absolute,
`cwd`-relative, `PATH`, and symlink launches; full `COSMIC_PORTABLE_*`
environment scrubbing; rejection of standard, equal, and unrepresentable
private descriptor fields and of a differing executing core; a warm cache
staying usable when a nonselected core range is corrupt while a cold launch
still rejects a corrupt selected range while extracting it; and three
atomic races at the FIFO pause -- replace, unlink, and a pre-open mismatched
replacement that must be rejected rather than falling back to "no tree to
boot". Atomic replacement and unlink at that pause prove both VFS and the
trusted `build.artifact` prefix capability keep reading the retained
artifact descriptor; writing that same inode in place remains unsupported
and is deliberately not presented as safe. It finishes with informational
cold/warm entry-timing observations that set no threshold.

`identity_test.tl` exercises the production retained-artifact route.
`test_identity_primary` builds two portable applications from the retained
prefix (`COSMIC_FIXTURE_RUNTIME`), checks logical executable paths, prefix
reuse, suffix-only application edits, one shared cache entry,
unlink-and-rename-while-building races, and rejection of a corrupt
nonselected core before an application is published. It also uses one work
database successively with real release and sanitized cores, a changed
runtime basis, an unchanged repeat, a spoofed project database, and a
missing-runtime-identity refusal: changed runtime contexts run, while
unchanged and application-only contexts stand. It finishes by snapshotting
the finished project under the shared process `TMPDIR` and restoring that
snapshot fresh (`check_transported`) -- mirroring
a cross-host CI artifact hand-off, transported here by copy rather than
upload -- and proves the transported project keeps its application database
content and produces byte-identical, executable application output. A full
CI run (merge queue, main, or a manual run) runs this complete identity
proof independently on every native host.
Mutable developer state remains local to one runner; cross-platform support
is established by executing and attesting the same immutable product bytes
in all supported platform environments.

`self_rebuild_test.tl` archives a fresh `git archive HEAD` tree per case
(`COSMIC_FIXTURE_ROOT`) and places the fixture-only runtime
(`COSMIC_FIXTURE_RUNTIME`) at its `o/bin/cosmic`. Each child selects only
`embed_test.tl`, so unrelated tests remain untouched and cannot run. It uses
the same fixture-only startup pause to
rename and unlink the artifact after descriptor adoption. In each case a
deterministic Teal edit causes exactly one database-only rebuild and
re-entry at the same logical portable path, with the exact re-entered argv
and an ordinary environment value checked on arrival. The rebuilt file
keeps the retained prefix and cache entry count, and its bytes change. A
subsequent core input edit (`core/startup.h`) is refused, under
`COSMIC_AUTO_BOOT=0`, with the named `bin/zig build boot` remedy and touches neither the artifact nor the cache.
Three further cases -- a pinned `vendor/tl` version, an unapplied
`patch/tl` entry, and an edited `build/launcher.tl` -- are refused
outright, before `test.run` or the artifact is ever reached. A last,
dependency-free case exercises the prefix comparison itself: an exact
match, a too-short program, and a single mutated byte.

The pinned CI driver owns full-suite execution, retained output, working
database snapshots, delayed boundaries, and artifact immutability checks.
In a full run it runs portable suites from a fresh tracked-source export on
every leg, including the `alpine-x86_64` job container, which builds and
tests natively on musl/BusyBox like every other leg. Its isolated project and
command contracts are documented in `ci`.
