In runner mode a `check.needs`/`check.reap` skip AFTER a recorded
failure masks the failure as a file-level skip. cosmic/test.tl:146-155
continues past a failed case, but needs/reap still `os.exit(EXIT_SKIP)`
mid-run (cosmic/check.tl:256,297) — from inside a later case the
process dies before the counts line, `.got` records exit 2,
records.status_of says "skip", and report() prints stdout only for
fail rows, so the earlier failing case's line is buried in `.out`.
Under legacy mode the first failure killed the file with exit 1 before
any later skip could fire, so this ordering regression is new with
#1459. Live sites in already-migrated files: _make/stage_test.tl:179,
_tool/coverage/baseline_test.tl:325,425, plus in-test check.reap
callers. Likeliest exactly where earlier tests also break (a cold or
degraded checkout) — a red run reads as an environment skip. Fix
direction: the runner records a pending-failure flag and reports fail
even when the process exits with EXIT_SKIP after a recorded failure
(or needs/reap inside a case become case-level skips).
