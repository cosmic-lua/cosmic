## Change

Measured 2026-08-30: `_work/gitverdict_test.tl:86-95`
(`test_already_judged_refusal_names_the_way_forward`) pins the refusal
guidance by calling the exported helper `vrd.already_judged_refusal`
directly, while the end-to-end pair-refusal test (lines 54-77) asserts
only exit codes and never reads the printed message (no `:find(` on the
output in that test). One line connects helper to output
(`"REFUSED: " .. already_judged_refusal(id, head)` in
`_work/gitverdict.tl`), so a regression that re-inlines old text in
`cmd_verdict` while leaving the helper exported keeps both tests green.
The change is test-only, in `_work/gitverdict_test.tl`: the end-to-end
already-judged test captures the verdict line `cmd_verdict` actually
prints and asserts the guidance substring rides on it (`find` with
`, 1, true`). Mutation-verify by re-inlining a stale message at the
`cmd_verdict` call site (leaving the helper untouched) and watching the
new assertion go red; restore, green.

## Non-goals

No production-code change. The helper-level pin stays (it localizes
failures); this adds the printed-line pin beside it.
