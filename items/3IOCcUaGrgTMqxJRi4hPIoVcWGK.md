The contract the rest of the test-runner work lands against, written
with the `decide` skill into docs/decisions: tests are discovered by
name (`local function test_*`), invoked by a toolchain-generated
in-chunk tail rather than self-calls, a file is all-or-nothing
(every test self-called = legacy, none = runner, mixed = lint
failure), and the 0/2/fail exit grammar is unchanged. The tradeoffs
and rejected alternatives (registration API, body extraction, _ENV
scanning, a t handle) are already argued in
docs/design/test-runner.md on branch claude/cosmic-test-runner-rgb819;
the record distills them into the settled form the index gates.
