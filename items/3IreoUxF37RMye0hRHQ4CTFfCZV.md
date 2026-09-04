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

**Corroborated again 2026-09-04, a later `/work 9 --routine` pass
(friction log `friction-2026-09-04-work9.md`, filed alongside this
item's original)**: of 5 accept verdicts recorded on `board`-targeting
PRs across that pass, **3 independently hit the identical
`enable_pr_auto_merge` dead end** before any brief fix had landed:

- review-sxzp_M1yR-d6f1cc41 (PR #1706): hit it, found the fix via
  `gitboard help review`, merged directly (squash).
- review-mzpu_OKna-d6f1cc41 (PR #1707): hit it, correctly stood down per
  its brief rather than guessing, reported it as a blocker — orchestrator
  merged manually.
- review-LmNB_gMXm-d6f1cc41 (PR #1710): hit it, sampled 20 recent closed
  `board`-PRs via the GitHub API to check whether the gap was systemic,
  correctly concluded the brief's instructions don't cover this branch —
  orchestrator merged manually.

Only once the orchestrator started hand-appending an ad hoc correction to
each review brief for a `board`-targeting PR (starting with
review-nwzb_73yW-d6f1cc41, PR #1711) did reviewers merge directly on the
first attempt with no dead end — validating that the `## Change` below
(branching the brief's own text on `base`) is sufficient to close this
gap once it ships; two further round-2 reviews this same pass
(review-4B0h_t06K-d6f1cc41, review-VbI3_FiHP-d6f1cc41) also landed clean
once briefed with the same ad hoc correction.

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
