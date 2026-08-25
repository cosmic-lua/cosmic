Extract the token-exact lexer walk from `_cli/lint.tl`'s
check_call_after_define into a shared discovery module: classify a
test file as runner (no top-level `test_*` call), legacy (every
`test_*` self-called), or mixed, and yield the ordered case list of
top-level `local function test_*` definitions. The
`call-after-define` lint generalizes onto it: mixed is the one shape
that must never pass, legacy and runner both lint clean. Pure
refactor plus the rule change; no compile-seam consumer yet.
Context: docs/design/test-runner.md (branch
claude/cosmic-test-runner-rgb819).
