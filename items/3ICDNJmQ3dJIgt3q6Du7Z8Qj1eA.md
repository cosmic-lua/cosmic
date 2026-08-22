## Goal

G8 — the flow system. The merge lands the head a reviewer accepted,
or it does not land: `land` compares the accepted head against the
PR's current one, and GitHub's own `sha` guard enforces it on the
server.

## Evidence

Re-measured 2026-08-22 at board head `e7cd0c84`.

`_work/gitland.tl` fetches the PR and has `p.head_sha` in hand; the
item carries `verdict_head` (written by `cmd_verdict` since the
verdict verb existed). **No comparison is made.** `_work/gh.tl`'s
`merge` sends `{merge_method = "squash"}` and nothing else — GitHub's
`sha` parameter, which exists to refuse a merge when the head moved,
is not sent (`grep -n 'merge_method' _work/gh.tl` is one line, line
149).

Scenario, entirely within the tool: a reviewer accepts at head H;
the builder pushes more commits; any session runs `land`; the PUT
merges the new head, and nothing anywhere recorded that what merged
is not what was judged.

The already-merged branch (`gitland.tl:61-63`, from #1284) has the
same blind spot from the other side: it ends the item `completed`
without looking at what merged relative to the accept.

## Change

Three files. The decision is a PURE classifier so it is testable
without a network, the way `blocks_check`, `blocks_on_ci` and
`blocks_accept` already are.

1. **`_work/review.tl` gains `blocks_land(p: Pull, verdict_head:
   string): string`** — the refusal a landing earns, nil when the
   merge may proceed. It returns nil when `verdict_head` is `""` (an
   item accepted before the field was written has nothing to compare,
   and refusing those would strand them). It refuses when
   `verdict_head ~= p.head_sha`:
   `PR #N has moved since the accept — judged HEAD7, now HEAD7; re-review the current head or --force`
   with both shas at 7 characters. `wc -l < _work/review.tl` is 123.

2. **`_work/gh.tl`'s `merge` takes the head sha** and sends it:
   `merge(s, number, repo, sha)` → `{merge_method = "squash", sha =
   sha}` when `sha ~= ""`, and exactly today's body when it is `""`.
   GitHub answers **409** when the head has moved, so `refusal` gains
   a 409 branch naming that specifically — the guard is what makes
   409 reachable, so classifying it belongs in this slice:
   `REFUSED (409: PR #N moved between the accept and the merge and nothing was merged; re-review the current head)`.
   405 and the rest keep today's generic branch (a separate seam,
   noted below). `wc -l < _work/gh.tl` is 205.

3. **`_work/gitland.tl` wires both.** Before the merge, call
   `review.blocks_land(p, it.verdict_head)` and, unless `--force`,
   return `gate.verdict_line("land", false, "REFUSED: " .. refusal)`.
   Pass `it.verdict_head` to `gh.merge`. On the already-merged branch,
   do NOT refuse — the merge cannot be undone and refusing would
   strand the item forever — but when `blocks_land` would have fired,
   print
   `gitboard-land: WARNING PR #N merged at HEAD7 but the accept judged HEAD7`
   before ending the item, so the discrepancy is in the log rather
   than nowhere. `wc -l < _work/gitland.tl` is 85.

4. **Tests.** `_work/review_test.tl` (107 lines) gains
   `test_blocks_land_compares_the_accepted_head`: equal shas (nil),
   differing shas (refusal naming both), and an empty `verdict_head`
   (nil). `_work/gh_test.tl` (46 lines) gains a 409 case to
   `refusal`, asserting it is distinct from both the 403 wall and the
   generic branch.

## Non-goals

- **The 405 classification stays as it is.** The capture notes that
  branch protection and closed PRs report 405 into the generic
  "re-run land once the cause clears" branch. That is a real second
  seam and it is 3I8lUm1r's; only 409 is in scope here, because the
  `sha` guard is what makes 409 reachable at all.
- No change to `cmd_verdict` or to what `verdict_head` means: it is
  the head the reviewer judged, written by the verdict, read here.
- The already-merged branch keeps ending the item `completed`. A
  merge cannot be undone; the fix is a loud record, not a refusal.
- No new field on `Item`.
- `--force` keeps its existing meaning on `land` and skips the new
  refusal along with the others.
- No change to the `gitboard-land:` verdict-line prefix.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/review_test.tl _work/gh_test.tl` ends
  `test: PASS`, including `test_blocks_land_compares_the_accepted_head`
  and the 409 case.
- `grep -c 'sha = ' _work/gh.tl` is at least 1 (it is 0 today).
- `grep -c 'blocks_land' _work/gitland.tl` is 1.
- `wc -l < _work/review.tl` ≤ 200, `wc -l < _work/gh.tl` ≤ 260,
  `wc -l < _work/gitland.tl` ≤ 140.

## Enablement

none needed — `review.tl` already carries three classifiers of
exactly this shape and `review_test.tl` tests them over literal
`Pull` values, which is the whole pattern this follows;
`_work/gh_test.tl` already tests `refusal` by status the same way.
The wrong turn to predict is refusing on the already-merged branch:
it reads like the symmetric fix and it strands the item permanently,
because the merge cannot be undone. `Change` and `Non-goals` both say
warn-and-complete there.
