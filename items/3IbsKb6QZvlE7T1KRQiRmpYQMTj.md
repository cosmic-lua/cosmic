## Change

Both refusal strings that chain in the same-session repair path must
name the audited escape. Measured 2026-08-30 (fresh sweep):
`already_judged_refusal` (`_work/gitverdict.tl:61-67`) advises running
`gitboard spec` and re-recording the verdict, but never names
`--force --why`; when the SAME session follows that advice it becomes a
speccer, and `gate.distance_refusal` (`_work/gitgate.tl:151-166`) then
refuses its verdict with "REFUSED: %s built/specced %s — the verdict
needs a fresh context" — which also never names `--force --why`, even
though that guard's own doc comment (`_work/gitgate.tl:144-150`) states
`--force --why` is the audited repair path. The change is message text
only, in both strings: `already_judged_refusal` gains a sentence noting
that a same-session re-record after the respec trips the distance guard
and `--force --why <reason>` is the audited repair; `distance_refusal`'s
message names `--force --why` as its own repair escape. Pin both new
substrings in `_work/gitverdict_test.tl` — on the PRINTED `cmd_verdict`
output for the distance path (the end-to-end printed-line seam added by
item Td76up8O's PR, which lands before this one), and mutation-verify
each pin red against the old text.

## Non-goals

No guard-behavior change: both paths still refuse; only the words
change. No new flags.
