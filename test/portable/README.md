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
