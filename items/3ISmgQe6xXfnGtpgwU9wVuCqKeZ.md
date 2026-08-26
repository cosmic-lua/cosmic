`skills/work/review.md` (lines 104-111 at main `ec794d44`) tells the
reviewer of a research slice to run `done ID` after an accept:

> a research slice (deliverable: recorded findings, no PR) takes the
> same three verdicts: accept means re-running the spec's acceptance
> checks against the tree ... then `done ID`, with no move into
> `land` because there is nothing to merge.

3ISltQMh settles the tool half of that sentence by having
`verdict ID accept` END a PR-less item inside the accept itself,
reusing the shape `_work/gitverdict.tl` already has for an
already-merged PR — one mutation, no window where an accepted item
sits open. Once that lands, the `then \`done ID\`` clause is stale:
a session following it would run `done` on an item the accept already
closed and read a refusal.

The fix is one clause in `review.md` — the accept ends it, nothing
further to run. Filed separately because 3ISltQMh is `board`-branch
machinery and this is `main` prose; one branch is one PR is one slice.
