## Evidence

Measured across the `/work 9 --routine` orchestrator pass on 2026-09-04
(friction log `friction-2026-09-04-work9.md`, filed alongside this item):
of 5 reviews that returned `accept` on a `board`-targeting PR this pass,
**3 independently hit the same dead end** trying to land it — each ran
`enable_pr_auto_merge` (squash) per the review brief's unconditional
instruction ("a main-repo PR lands by enabling auto-merge... never by
merging directly"), and each got the identical GraphQL failure:

```
GitHub GraphQL error on enable_pr_auto_merge: Pull request Protected
branch rules not configured for this branch
```

- review-sxzp_M1yR-d6f1cc41 (PR #1706): hit it, discovered the fix via
  `gitboard help review` (which DOES document the board-PR exception,
  separately from the brief), merged directly.
- review-mzpu_OKna-d6f1cc41 (PR #1707): hit it, correctly stood down per
  its brief's instruction not to merge directly, reported it as a blocker
  for the orchestrator instead of guessing — orchestrator merged manually.
- review-LmNB_gMXm-d6f1cc41 (PR #1710): hit it, went further and sampled
  20 recent closed `board`-PRs via the GitHub API to check whether this
  was systemic, correctly concluded the brief's landing instructions don't
  cover this branch's actual mechanics, flagged it — orchestrator merged
  manually.

Only after the orchestrator started hand-appending an ad hoc correction
to review briefs for `board`-targeting PRs (starting with the
review-nwzb_73yW-d6f1cc41 review, PR #1711) did a reviewer merge directly
without hitting the dead end.

Root cause: `gitboard`'s `board` branch has no GitHub branch-protection
rule (it's an orphan branch this repo's own tooling lives on), so
`enable_pr_auto_merge`'s GraphQL mutation — which requires branch
protection to be meaningful — always fails there. `gitboard help review`
already documents that a board PR "merges directly," but the emitted
review brief's "Recording your verdict" → accept instructions state the
auto-merge path unconditionally, with no branching on the PR's target
branch, so a reviewer following the brief alone (not separately consulting
`help review`) has no way to know the instruction doesn't apply.

## Change

`_work/brieftext_review.tl` (or wherever the review template's "Recording
your verdict" accept instructions render): branch the accept landing
instructions on the item's recorded base/target branch — `board` merges
directly (squash), any other branch (e.g. `main`) uses
`enable_pr_auto_merge` (squash), never a direct merge. State both branches
explicitly rather than leaving the board case to `gitboard help review`
alone.

Alternatively (equal or higher leverage, orchestrator's call): have
`gitboard verdict`'s `accept` output itself print the correct landing
instruction for the item's recorded base, so the fix lives in one place
regardless of which brief template renders it.

`_work/brieftext_review_test.tl` (or the appropriate pin-test file): pin
that a `board`-based item's rendered review brief says "merge directly"
and a non-`board` item's says "enable auto-merge."

## Non-goals

Not changing `enable_pr_auto_merge`'s actual behavor or adding branch
protection to `board` — the orphan branch's shape is a deliberate design
choice ([D-something noted in AGENTS.md's build system section]); this is
purely a brief/tool text fix so reviewers stop discovering the mismatch by
trial and error.
