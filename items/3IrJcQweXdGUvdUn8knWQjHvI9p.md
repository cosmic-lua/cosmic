## Evidence

Review agent review-sWmK_pFNW-41598fb4 (2026-09-04, reviewing PR #1696
against `board`) recorded an `accept` verdict, then tried to land it by
calling `enable_pr_auto_merge` (per the emitted brief's instruction: "a
main-repo PR lands by enabling auto-merge (squash), never by merging
directly"). It failed twice with `Protected branch rules not configured
for this branch` — the orphan `board` branch this repo's work-item PRs
target has no branch-protection configured, so GitHub's auto-merge is
unavailable there. The reviewer correctly declined to merge directly
(the brief said never to), left the PR open with the verdict recorded,
and reported the blocker; the orchestrator then had to merge PR #1696
directly by hand to unblock landing.

`_work/doctrine.tl:269-270` (what `gitboard help review` prints) already
states the correct, narrower rule: "`accept` — merge (a main-repo PR
lands by enabling auto-merge; a board PR merges directly)". The text
`gitboard brief review` actually emits — `_work/brieftext.tl:257-260` at
time of writing (may have moved to `_work/brieftext_review.tl` if
«rNh1_b1Se»'s file-split PR has landed by the time this is picked up;
`grep -n 'a main-repo PR lands by enabling auto-merge' _work/*.tl` finds
it either way) — dropped the board-PR branch entirely, unconditionally
telling every reviewer "never merge directly" regardless of which
branch the PR targets.

## Change

In whichever `_work/brieftext*.tl` file contains the line "a main-repo
PR lands by enabling auto-merge (squash), never by merging directly.",
replace it with the two-branch rule `_work/doctrine.tl` already states:
a PR against `main` (or whatever the item's own `base` field says other
than `board`) lands via auto-merge; a PR against `board` merges
directly. The brief already has the item's `base` available when it is
filled (it is printed in `gitboard show`'s header and used to compose
step 8's "Open a PR from BRANCH to <base>" instruction in the builder
brief) — thread the same value into the review brief so the "accept"
instruction names the correct landing method for THIS item without the
reviewer having to guess or hit the auto-merge failure first.

`_work/brief_test.tl` (or `brieftext_test.tl`/`brieftext_review_test.tl`,
wherever the existing `Board:`-line-style pins for this template live):
one fixture item with `base: board` asserts the emitted review brief's
accept instruction says "merges directly"; one with `base: main` (or any
non-`board` value) asserts it says "enabling auto-merge".

## Non-goals

Not a change to the merge mechanics themselves (`gitboard verdict`,
`done`, or the actual merge tool calls) — the fix is entirely in what
the emitted brief TELLS the reviewer to do; the orchestrator's own
landing step (calling the merge tool once accept is recorded) is
unaffected. Not a change to `_work/doctrine.tl`, which already states
the correct rule.
