## Evidence

`gitboard new TITLE --spec-file F --repo OWNER/NAME` with no
`--parent` refuses with `claim/reviewer/pr/verdict/repo/base belong to
worked items, not roots` (`_work/item.tl:240`): a parentless item is a
root, and a root carries no repo. The 2026-09-04 routine log records
two occurrences (two failed calls each) before the working sequence
was found by trial — `new`, then `attach`, then `set --repo`. `new
--parent P --repo R` in one call works today and is the shortest fix;
the refusal names what is disallowed and not either path to what the
caller wanted.

## Change

`_work/item.tl:240` (or the `new` verb's own check in
`_work/gitgraph.tl`, whichever runs first for `new`): when the refused
field is `repo` or `base` on a parentless `new`, the refusal reads
"a root carries no repo: pass `--parent ID` to file it under an
outcome, or `new` it bare and `attach`, then `set ID --repo`". Other
fields keep the current text. `gitboard help new`'s `--repo` option
text gains "(needs --parent)".

`_work/gitgraph_test.tl`: pin the refusal text for `--repo` without
`--parent`, and that `--parent` plus `--repo` succeeds.

## Non-goals

No change to what a root may carry.
