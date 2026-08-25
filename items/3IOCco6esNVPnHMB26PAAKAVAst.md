A new public module `cosmic/test.tl`: `main(cases)` takes an ordered
{name, fn} list, runs each under pcall, records name + error +
traceback on failure and continues to the next test, prints per-test
failures and a counts summary in the records grammar, honors a
COSMIC_TEST_FILTER substring (exit 2 when the filter matches none,
mirroring the example runner), and exits by the 0/2/fail grammar
(exit 2 when the list is empty). Standalone and callable by hand
before any toolchain change; `cosmic/test_test.tl` pins
continue-past-failure, the skip shapes, and that a failing test's
output names the function. Shape and semantics:
docs/design/test-runner.md (branch claude/cosmic-test-runner-rgb819).
