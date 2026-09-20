# Portable characterization fixture

`characterize.sh` runs a copied standalone project against the packed portable
prototype. The checked-in Teal sources end in `.tl.in`, so Cosmic's own build
does not stage them as project modules or tests.

This fixture deliberately records two current gaps. `build` exits 1 with
`this binary names no host target` and `build: FAIL`. `test` succeeds and runs
the fixture once, but the packed database has no `runtime` metadata. A second
run changes the fixture's target/runtime labels; its passing verdict keeps the
same key, stands, and leaves the test's external counter unchanged. The labels
are deterministic stand-ins for the validated core context that does not exist
yet, not a proposed runtime interface.

Commit 6 flips the identity assertions: the artifact must expose a nonempty
runtime identity, and changing real target, core digest, release/sanitized
configuration, or runtime basis must produce a different verdict key and run
the test again. An unchanged repeat must still stand. The build assertion
changes in commit 6 only from missing target to the later `image_of` failure;
portable build does not pass until commit 7.

`runtime_build.sh` and `runtime_test.sh` cover step 5 with real Cosmic cores and
the real Cosmic database. A fixture-only core build contains a deterministic
FIFO pause after descriptor validation and before SQLite opens the main
database; ordinary cores contain neither the hook code nor its environment
names. Atomic replacement and unlink at that pause prove both VFS and the
trusted `build.artifact` prefix capability keep reading FD 8. The retained
descriptor selects one complete immutable file. Writing that same inode in
place remains unsupported and is deliberately not presented as safe.
