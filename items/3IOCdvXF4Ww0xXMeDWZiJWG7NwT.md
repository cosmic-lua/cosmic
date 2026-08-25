After a release ships the dual-mode toolchain, delete the legacy
arm: self-calling test files stop being a supported mode, the
generalized call-after-define lint rule is removed, and `.lua` test
files (copied, not compiled — no tail seam) are documented as the
one remaining self-calling script shape. A release note marks the
break, per the right-to-break doctrine. Context:
docs/design/test-runner.md (branch claude/cosmic-test-runner-rgb819).
