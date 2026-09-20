# Portable artifact fixtures

`identity_test.sh` exercises the production retained-artifact route. It builds
two portable applications from the retained prefix, executes canonical Linux
application bytes unchanged on all three hosts, checks logical executable
paths, prefix reuse, suffix-only application edits, one shared cache entry,
unlink-after-startup builds, and rejection of a corrupt nonselected core before
an application is published. It also uses
one work database successively with real release and sanitized cores, a changed
runtime basis, an unchanged repeat, and an application-database-only change.
Changed runtime contexts run, while unchanged and application-only contexts
stand.

`runtime_build.sh` and `runtime_test.sh` retain step 5 coverage with real Cosmic
cores and now use step 6's host-independent projection. A fixture-only core
build contains a deterministic
FIFO pause after descriptor validation and before SQLite opens the main
database; ordinary cores contain neither the hook code nor its environment
names. Atomic replacement and unlink at that pause prove both VFS and the
trusted `build.artifact` prefix capability keep reading the retained artifact
descriptor. It selects one complete immutable file. Writing that same inode in
place remains unsupported and is deliberately not presented as safe.

`runtime_build.sh OUTPUT [PREBUILT_PREFIX [WRITER PORTABLE_DATABASE]]` normally
uses a booted checkout's `o/bin/cosmic` and `o/cosmic.db`. With no
prebuilt prefix it invokes
`bin/zig build portable-fixture-cores` once in a temporary directory, sharing
one patched-vendor graph across the three release cores, three fixture-hook
cores, and the distinct sanitized core. A supplied prefix must contain
`targets.tsv`, release cores under `core/<target>/cosmic-core`, hook cores under
`portable-fixture/core/<target>/cosmic-core`, and the checked core at
`portable-fixture/sanitized/cosmic-core`; every input is checked before output
is generated. The explicit four-argument form lets CI combine the x86
producer's release/hooked cores and Cosmic/database with the checked core that
the sanitized job already tested, without compiling that core a second time.

`product_build.sh` makes the per-host provenance bundle from a booted tree. It
copies portable Cosmic, extracts its exact prefix and manifest, and uses those
same local portable bytes to build the hello and second standalone fixtures.
The bundle also carries every generated release target's raw core. Extraction
checks that each core occurs exactly once, at its manifest range, in Cosmic and
both applications. `product_test.sh` verifies every recorded transported hash,
exact prefix reuse, the selected manifest range's length, digest, and raw-core
bytes, and both applications. On the macOS host it also sends that extracted
range to strict `codesign` verification. Normal CI compares the complete bundle
from independent x86 Linux, ARM Linux, and ARM macOS producers.

The generated launcher uses POSIX shell builtins plus `uname`, `stat`, `id`,
`mkdir`, `chmod`, `mktemp`, `dd`, `head`, `ln`, `rm`, and either `sha256sum` or
`shasum`. The directory containing the cache leaf is the user's trust boundary;
the launcher rejects a linked leaf, unexpected owner or mode, and unexpected
entries. A warm launch still stats and hashes the complete cached core before
execution. `COSMIC_PORTABLE_CACHE` is the public cache setting. The remaining
`COSMIC_PORTABLE_*` fields are a reserved launcher-to-core contract: startup
requires the complete set, adopts its descriptors, and clears it before Lua
runs.

`self_rebuild.sh` uses that fixture-only startup pause to rename and unlink the
artifact after descriptor adoption. In each case a deterministic Teal edit
causes exactly one database-only rebuild and re-entry at the same logical
portable path. The rebuilt file keeps the retained prefix and cache entry, and
an ordinary environment value reaches the re-entered tests. A subsequent core
input edit is refused with the named `bin/zig build boot` remedy and does not
change the artifact.

Normal CI transports the identity fixture's whole project, including its one
`o/build.db`, from x86_64 Linux to aarch64 Linux and then aarch64 macOS. Each
actual host must run under its selected raw core, while an immediate repeat on
that host stands. This identity chain complements the independent per-host
product builds and the canonical full-suite run on every host.

`full_suite.sh` runs the CI full-suite diagnostics locally as five
explicit phases: `prepare`, `local`, `local-boundary`, `portable`, and
`portable-boundary`. Give every phase the same absolute diagnostics directory
outside the checkout. For example, after `bin/zig build cores boot`:

```sh
diagnostics=/tmp/cosmic-work-db-diagnostics
test/portable/full_suite.sh local "$diagnostics"
test/portable/full_suite.sh local-boundary "$diagnostics"
test/portable/full_suite.sh prepare "$diagnostics/transported" o/bin/cosmic
test/portable/full_suite.sh portable "$diagnostics/transported"
PORTABLE_OUTCOME=success \
  test/portable/full_suite.sh portable-boundary "$diagnostics/transported"
```

Both test phases retain the 30-second suite limit when `timeout` or `gtimeout`
is available. On macOS without either command, the workflow reports that it is
relying on the existing 20-minute job bound. A local run without either timeout
command refuses to start the suite rather than running without a bound.
`prepare` accepts an optional portable artifact, and `snapshot_work_db.sh`
accepts an optional Cosmic verifier. Normal CI uses both forms to run one
downloaded canonical artifact in a fresh checkout with no booted executable,
copied working database, verdicts, or cache. Both drivers are POSIX shell so
the same checks run under stock Alpine BusyBox.

`snapshot_work_db.sh DIAGNOSTICS-DIRECTORY LABEL` is also independently
runnable. It copies and hashes the raw working database and any journal before
opening a second, disposable copy with `work_db_integrity.tl.in`. The helper is
compiled outside the checkout, so diagnostics cannot stage a fixture source in
the product's working database. Both scripts reject a diagnostics directory in
the checkout.
