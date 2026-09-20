# Portable characterization fixture

`characterize.sh` runs a copied standalone project against the packed portable
prototype. The checked-in Teal sources end in `.tl.in`, so Cosmic's own build
does not stage them as project modules or tests.

`characterize.sh` deliberately keeps the old packed prototype visible. Its
`build` still exits 1 with `this binary names no host target` and `build: FAIL`.
Its database has no `runtime` metadata, which is now rejected before a test or
verdict can be recorded instead of being treated as the empty identity.

`identity_test.sh` exercises the production retained-artifact route. It uses
one work database successively with real release and sanitized cores, a changed
runtime basis, an unchanged repeat, and an application-database-only change.
Changed runtime contexts run, while unchanged and application-only contexts
stand. The target overlay lets portable `build` reach the expected absent
legacy-image boundary; portable build does not pass until step 7.

`runtime_build.sh` and `runtime_test.sh` retain step 5 coverage with real Cosmic
cores and now use step 6's host-independent projection. A fixture-only core
build contains a deterministic
FIFO pause after descriptor validation and before SQLite opens the main
database; ordinary cores contain neither the hook code nor its environment
names. Atomic replacement and unlink at that pause prove both VFS and the
trusted `build.artifact` prefix capability keep reading FD 8. The retained
descriptor selects one complete immutable file. Writing that same inode in
place remains unsupported and is deliberately not presented as safe.

The portable workflow transports the identity fixture's whole project,
including its one `o/build.db`, from x86_64 Linux to aarch64 Linux and then
aarch64 macOS. Each actual host must run under its selected raw core, while an
immediate repeat on that host stands. This is focused identity evidence; the
normal portable full-suite and provenance workflow remains step 9.
