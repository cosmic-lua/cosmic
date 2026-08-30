## Change

Evidence (builder of PR #1541, 2026-08-30): AGENTS.md's testing
bullet still states "test files call each test where they define it:
a `test_*` function in a `_test.tl` is called on the line after its
`end`", but D29 (docs/decisions/d29-tests-run-because-defined.md)
moved test files to runner mode — the toolchain discovers
`local function test_*` definitions and calls them via a generated
tail, and adding a self-call to a runner-mode file makes it "mixed",
a lint FAILURE (a builder following the prose verbatim hit
warnings-as-errors and had to back the self-call out). Migration is
in flight (`migrate to runner mode, batch N/7` items own the code
side), so BOTH conventions exist in the tree today.

The change, prose only, in AGENTS.md (and any other main-tree doc
asserting call-after-end — sweep with
`grep -rn "line after its" AGENTS.md docs/ skills/` and widen the
needle if it matches nothing): rewrite the testing bullet to describe
the actual current rule. Before writing, READ
docs/decisions/d29-tests-run-because-defined.md and the lint's own
source for what it enforces (grep _tool/ and _cli/ for the
mixed/runner detection) — the bullet must state when a file is
runner-mode vs legacy, what the lint refuses, and what a NEW test
file should do. Keep it as compact as the surrounding bullets.

## Non-goals

No code or lint changes; no test-file migrations (the batch items own
those); no edits to skills/work/SKILL.md.
