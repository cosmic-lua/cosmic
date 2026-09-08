# public fuzzing proof of concept

The public API is `cosmic.fuzz`: byte inputs, recording generators,
structured results, property-process isolation, corpus replay and explicit
promotion. Cosmic's seven fuzz target files consume this API. The worker
protocol and versioned result storage are shared by generated checks, corpus
checks and explicit replay.

## boundaries

This POC preserves failure identity at the category level. It does not claim
a globally minimal input, deterministic arbitrary generators, or that one
input reproduces a failure caused by prior checks. A non-reproducing replay
keeps the original failure and artifact. Sequence recording, sequence replay
and sequence minimization are follow-up work.

Capture closes a regular file before entering the checked code. This covers
worker-process crashes; machine or power failure durability is outside the
contract. A torn capture is refused rather than interpreted as a valid
input. One file write before generation and one before each check add I/O to
the hot path. Measure that cost before expanding this into a coverage-guided
engine or changing the capture transport.

The public API ships with the runtime's ordinary public module payload,
including the assertion helper's `cosmic.check` dependency. This trades some
artifact size for a standalone testing facility. Helper modules under
`cosmic.fuzz.*` are implementation structure; the POC's supported entrypoint
is `cosmic.fuzz`. Recorder and Draw types and replay_source are exported
through that entrypoint.

## gitboard migration after a release

1. Choose a Cosmic release containing `cosmic.fuzz` and update gitboard's
   verified `bin/cosmic.pin` to that release and checksum.
2. Change imports from `_fuzz.driver` to `cosmic.fuzz`. Replace
   `_fuzz.source` type references with `fuzz.Recorder` and `fuzz.Draw`;
   use `fuzz.replay_source` to interpret a recorded draw tape.
3. Replace `local ok, message = driver.run(opts); check.truthy(ok, message)`
   with `local result = fuzz.run(opts); fuzz.assert_ok(result)`.
4. Give properties names unique within their entry script and corpus root.
   Keep `--- env: FUZZ_SEED FUZZ_ITERS`; add `--- reads: testdata/fuzz`, or
   the explicitly configured corpus directory.
5. Ensure each check derives its expectations from its input. Encode any
   expected value or generator choices in those bytes instead of reading
   hidden state left by the generator.
6. Run gitboard's item-tree and priority fuzz targets, their unit tests, and
   its ordinary CI gate; then remove its copied driver/source/shrinker.
7. Retain failure directories from the CI job even when the test step fails.
   Promote reviewed input files explicitly into `testdata/fuzz`.

A source-only compatibility shim does not satisfy this migration: gitboard's
pinned runtime must actually carry the public modules. No gitboard pin or
release is changed by this POC.
