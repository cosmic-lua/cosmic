# Portable characterization fixture

`characterize.sh` runs a copied standalone project against the packed portable
prototype. The checked-in Teal sources end in `.tl.in`, so Cosmic's own build
does not stage them as project modules or tests.

`characterize.sh` deliberately keeps the old packed prototype visible. Its
`build` still exits 1 with `this binary names no host target` and `build: FAIL`.
Its database has no `runtime` metadata, which is now rejected before a test or
verdict can be recorded instead of being treated as the empty identity.

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

The portable workflow transports the identity fixture's whole project,
including its one `o/build.db`, from x86_64 Linux to aarch64 Linux and then
aarch64 macOS. Each actual host must run under its selected raw core, while an
immediate repeat on that host stands. This is focused identity evidence; the
normal portable full-suite and provenance workflow remains step 9.

`full_suite.sh` runs the normal CI full-suite diagnostics locally as five
explicit phases: `prepare`, `native`, `native-boundary`, `portable`, and
`portable-boundary`. Give every phase the same absolute diagnostics directory
outside the checkout. For example, after `bin/zig build cores boot`:

```sh
diagnostics=/tmp/cosmic-work-db-diagnostics
test/portable/full_suite.sh prepare "$diagnostics"
test/portable/full_suite.sh native "$diagnostics"
test/portable/full_suite.sh native-boundary "$diagnostics"
test/portable/full_suite.sh portable "$diagnostics"
PORTABLE_OUTCOME=success \
  test/portable/full_suite.sh portable-boundary "$diagnostics"
```

Both test phases retain the 30-second suite limit when `timeout` or `gtimeout`
is available. On macOS without either command, the workflow reports that it is
relying on the existing 20-minute job bound. A local run without either timeout
command refuses to start the suite rather than running without a bound.

`snapshot_work_db.sh DIAGNOSTICS-DIRECTORY LABEL` is also independently
runnable. It copies and hashes the raw working database and any journal before
opening a second, disposable copy with `work_db_integrity.tl.in`. The helper is
compiled outside the checkout, so diagnostics cannot stage a fixture source in
the product's working database. Both scripts reject a diagnostics directory in
the checkout.
