Evidence (builder of PR #1541, 2026-08-30): AGENTS.md still states "a
`test_*` function in a `_test.tl` is called on the line after its
`end`", but D29 (docs/decisions/d29-tests-run-because-defined.md, PR
#1459) moved test files to runner mode — the toolchain discovers
`local function test_*` definitions and calls them via a generated
tail, and an explicit self-call makes the file "mixed", which is a
lint FAILURE. A builder following the AGENTS.md prose verbatim added a
self-call to `_make/clean_test.tl` and got warnings-as-errors on the
file's other, correctly-uncalled tests; removing the self-call fixed
the build. The change: update AGENTS.md's testing bullet (and any
other prose asserting call-after-end — sweep for it) to describe
runner mode, noting whatever transitional mixed/legacy rule the lint
actually enforces (read `_tool/` and D29 for the current rule). Note
the in-flight runner-mode migration items (`migrate to runner mode,
batch N/7`) own the CODE migration; this item owns only the stale
prose that misleads builders.
