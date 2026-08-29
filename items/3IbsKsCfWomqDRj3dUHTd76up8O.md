Evidence (fresh-context review of PR #1533, 2026-08-29): the substring
pin added in `_work/gitverdict_test.tl` asserts on the exported
`already_judged_refusal` helper, not on `cmd_verdict`'s printed output,
and only one line (`"REFUSED: " .. already_judged_refusal(id, head)` at
`_work/gitverdict.tl:160`) connects them. A regression that re-inlines
the old text in `cmd_verdict` while leaving the helper exported would
keep both the new pin and the pre-existing pair-refusal test green —
that end-to-end test (`_work/gitverdict_test.tl:79`) asserts only exit
codes, never the message — so the guidance could silently vanish from
the real refusal path. The reviewer's mutation had to target the helper
body to go red. The change: one assertion in the end-to-end
already-judged test capturing the printed verdict line and checking the
guidance substring rides on it.
