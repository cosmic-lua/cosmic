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

**Corroborated 2026-09-04, review-zvR2_ujhh-07d7b9b9-2**: a second
reviewer, already told (via an orchestrator-added note, since this fix
hadn't landed yet) to merge the board PR directly, still hit a second
gap the brief doesn't name: the default `merge_pull_request` call fails
with `405 Merge commits are not allowed on this repository` — this repo
accepts squash merges only. One extra call with `merge_method: "squash"`
resolved it. "Merge directly" alone is incomplete guidance; the method
matters too.

## Change

`_work/brieftext_review.tl`'s "Recording your verdict" section (around
lines 78-82): branch the accept-landing instructions on the item's own
`base` field (already available where the template is filled) —
`base == "board"` (or more generally, the board repo's own base) emits
"merge directly via squash (`merge_method: squash` — this repository
rejects merge commits), then `gitboard done ID`"; any other base keeps
the existing "enable auto-merge, do NOT call done" text.

`_work/brief_test.tl` (or wherever review-brief fill tests live): a
fixture item with `base: board` renders the direct-squash-merge text;
one with `base: main` renders the existing auto-merge text.

## Non-goals

No change to `gitboard verdict`/`gitboard done` themselves — this is
brief text only.
