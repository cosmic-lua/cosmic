## Evidence

`gitboard land` has no already-merged branch, so an item whose PR merged by any
other route cannot be finished with `land` at all.

Observed 2026-08-17 landing 3HyCS1Ew (#1261) and 3HyEla9L (#1262): the token
gitboard uses answered 403 on the squash-merge
(`gitboard-land: PR #1261: this token may not merge (403) — a human with write
access has to land it`), so both PRs were merged through a different credential.
Re-running `gitboard land 3HyCS1Ew` after #1261 was already merged printed the
same 403 line: `land` re-attempts `PUT /pulls/N/merge` unconditionally and
classifies the answer without first asking whether the PR is already merged.
The items had to be ended with `gitboard done ID`, which records `completed`
but is the generic end verb, not the landing one — so the board cannot
distinguish "landed" from "ended for some other reason" on exactly the items
where the distinction matters.

Suggested shape: before merging, read the PR; if `merged` is true (or the merge
call answers 405 "already merged"), end the item as landed and say so, rather
than reporting a merge refusal for work that is in fact on main. Distinct from
3I06cBmI, which classifies a *refused* merge; this is the case where nothing
was refused because there was nothing left to merge.
