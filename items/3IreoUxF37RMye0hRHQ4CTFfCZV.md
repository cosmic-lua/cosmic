## Evidence

`friction: 2026-09-04 work9` (this pass): reviewer review-Elus_cLzz-07d7b9b9
followed the review brief's generic "Recording your verdict" instructions
("a main-repo PR lands by enabling auto-merge, never merging directly...
do NOT call gitboard done") on item «Elus_cLzz», whose PR targets `board`,
not `main`. `enable_pr_auto_merge` failed with "Protected branch rules not
configured for this branch"; the reviewer then found via `gitboard help
review` that "a board PR merges directly, then `done ID`" and corrected
course — one extra tool call, and a brief that contradicted the doctrine
it should have carried directly.

## Change

`_work/brieftext_review.tl`'s "Recording your verdict" section (around
lines 78-82): branch the accept-landing instructions on the item's own
`base` field (already available where the template is filled) —
`base == "board"` (or more generally, the board repo's own base) emits
"merge directly, then `gitboard done ID`"; any other base keeps the
existing "enable auto-merge, do NOT call done" text.

`_work/brief_test.tl` (or wherever review-brief fill tests live): a
fixture item with `base: board` renders the direct-merge text; one with
`base: main` renders the existing auto-merge text.

## Non-goals

No change to `gitboard verdict`/`gitboard done` themselves — this is
brief text only.
