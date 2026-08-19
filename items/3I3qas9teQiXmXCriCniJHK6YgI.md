## Goal

G8 — the flow system: `land` finishes what is finished. An item whose PR
reached main by any route must be landable, or the board holds "accepted,
awaiting merge" state for work that is already on main.

## Evidence

`cmd_land` (`_work/gitland.tl`, 69 lines) attempts
`PUT /pulls/N/merge` unconditionally and classifies only that answer.
Observed 2026-08-17 (#1261, #1262) and again 2026-08-19 (item 3I5xg5TL,
PR #1278): this session's token gets 403 on the PUT
("Merging into a protected base branch is not permitted for this session
type"), the PR was merged through another credential, and re-running
`gitboard land` after the merge printed the same 403 — the tool never
asks whether there is anything left to merge. The item had to be ended
with bare `done`, losing the land verb's own trail line.

## Change

Ask before merging. Three files on the board branch, measured 2026-08-19:

1. **`_work/review.tl`** (82-line test file beside it; the `Pull` record
   is lines 11–19 and has no `merged` field — `grep -c merged
   _work/review.tl` is 0): add field `--- Already merged, by any route.`
   `merged: boolean` to `record Pull`.
2. **`_work/gh.tl`** (190 lines): in `pull()` (lines 43–70), parse it —
   `merged = v["merged"] == true` — beside the existing `draft` parse.
3. **`_work/gitland.tl`** (69 lines, well under cap): in `cmd_land`,
   after the `it.pr == 0` refusal and before `gh.merge`, fetch the PR:
   `local p, perr = gh.pull(s, it.pr)`. When the fetch fails, refuse with
   `("cannot read PR #%d: %s"):format(it.pr, perr)` — land already needs
   the API for the PUT, so a GET failure is the same wall named earlier.
   When `p.merged` is true, print
   `("gitboard-land: PR #%d was already merged"):format(it.pr)` and fall
   through to the existing `verbs.cmd_done(s, id, "completed", force,
   why)` — the commit trail's existing `done ID completed (from land)`
   line is what distinguishes a landing, and this path now earns it.
   When `p.merged` is false, proceed to `gh.merge` exactly as today.

The race window — a PR merged between the GET and the PUT — needs no new
classification: the PUT fails with the generic ERROR text, and the
re-run land's GET now answers merged and ends the item. Self-healing on
retry beats a second classifier.

## Non-goals

- no new resolution kind: "landed" stays `completed`-from-`land` in the
  trail, not a schema change.
- no change to `gh.refusal`'s 403/ERROR texts, to `review.blocks_check`
  (a merged PR is `closed` and still refuses `check` entry — correct),
  or to the merge method.
- no retry loops, no 405 sub-classification.
- `cmd_land`'s merge-then-done ordering for the unmerged path is settled
  by the module's own header comment; do not reorder it.

## Acceptance

- on the board worktree: `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -n "merged" _work/review.tl _work/gh.tl _work/gitland.tl` shows
  the field, its parse, and the pre-merge branch (three files, non-test
  matches ≥ 3).
- the network edge is `gh.tl`'s untestable-by-fixture boundary like the
  rest of that module (its `_test.tl` pins pure classifiers only, 37
  lines today); the observable contract above is exercised the next time
  any PR merges by another route — quote this spec's Evidence in the PR
  instead of inventing a mock.

## Enablement

none needed — the wrong turns a literal builder could take (block on GET
failure? new resolution kind? classify the race?) are each settled above.
