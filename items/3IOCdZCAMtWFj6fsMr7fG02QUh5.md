`_tool/testrun.tl` parses the child's per-test output into the
`.tests` sidecar as one name-and-status line per test (today the
sidecar carries names only), passes `--filter` through to the child
as COSMIC_TEST_FILTER, and `--report` totals tests rather than
files, naming each failing test. Legacy-mode files keep the
names-only sidecar they have today. Context:
docs/design/test-runner.md (branch claude/cosmic-test-runner-rgb819).
