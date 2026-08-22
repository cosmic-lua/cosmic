## Goal

G8 — the flow system. `verdict accept` reads the PR it is judging, so
an already-merged one completes the item in that same mutation and a
closed-unmerged one is refused instead of being routed to a landing
that can never happen.

## Evidence

Re-measured 2026-08-22 at board head `b855dc66`. **The capture's
central claim no longer holds**, and correcting it is what shapes this
slice:

> "`verdict ID accept` would move the item to land, where `gitboard
> land ID` tries to squash-merge an already-merged PR."

`_work/gitland.tl:56-64` reads the PR BEFORE merging and, on
`p.merged`, prints `gitboard-land: PR #N was already merged` and calls
`cmd_done`. That path landed in #1284 —
`git log -S "was already merged" --oneline -- _work/gitland.tl` names
the one commit. So an accepted item whose PR merged out of band is
**not stranded**: `verdict ID accept --session S` then `gitboard land
ID` completes it in two commands.

What IS broken, measured at the same head. `grep -c 'gh\.'
_work/gitverdict.tl` is **0** — the verdict verb never reads GitHub —
and that single fact produces both:

1. **A closed, unmerged PR at accept strands the item in `land`.**
   Nothing at accept consults the PR, so the item moves to `land`;
   `cmd_land` then reads it, `p.merged` is false, and `gh.merge` PUTs
   against a closed request, which GitHub refuses (405). `land`
   returns that refusal, `action.phased_action` answers `finish` for
   `landing[1]` again, and the pair repeats forever. This is the same
   livelock 3ICDNqdv closed for arrivals into `land`, still reachable
   because `cmd_verdict` moves an accept into `land` without going
   through `cmd_move`'s gate.

2. **A merged PR at accept costs a second command that does nothing.**
   The `land` step reads the PR, finds it merged, merges nothing, and
   ends the item. The state already said everything needed at accept.

Live instances of the merged case, both from this session: items
`3IE6ttNh` (PR #1320) and `3ICDOGbm` (PR #1321) sit in `check` with
PRs merged directly by the maintainer. Neither is stuck — each needs
one verdict from a non-claimant session, then a `land` that merges
nothing.

## Change

One read, added to `_work/gitverdict.tl`'s `cmd_verdict`, and the two
branches it enables. `wc -l < _work/gitverdict.tl` is 152.

1. **Read the PR on an accept.** After the existing builder-distance
   refusal and before the item is mutated: when `kind == "accept"`,
   the item names a PR (`(it.pr or 0) ~= 0`) and the board has an
   origin (`store.has_origin(s)`, the same guard
   `gate.handover_refusal` uses), call `gh.pull(s, it.pr, it.repo)`.
   A read that FAILS is not a refusal — fall through to today's
   behaviour, so a network outage cannot wedge reviews.

2. **Closed and unmerged is refused**: `p.state ~= "open" and not
   p.merged` returns
   `REFUSED: PR #<n> is <state> and unmerged — there is nothing to land; reopen it, or reject the item`.
   The item does not move.

3. **Merged completes the item in one commit.** Set `verdict`,
   `verdict_head`, and `pr` exactly as the accept path does today,
   then instead of `phase = "land"` set `phase = ""` and `resolution
   = "completed"`, and pass `gate.rephased_parent(it, all)` as the
   `also` argument to `commit_and_publish` — a container whose last
   open child just ended must return to `plan`, which is what
   `cmd_done` does and what this path would otherwise skip. Commit
   subject:
   `verdict <id8> accept (check -> completed) by <session>, merged <sha7>`,
   with the ` by <session>` half omitted when no session is named,
   exactly as the existing subject does. `<sha7>` is the merge commit,
   so the log records which merge completed the item without a new
   field on `Item`.
   Verdict line: `accept on <id8>: check -> completed (PR #<n> was
   already merged)`.

4. **`review.Pull` gains `merge_sha: string`**, parsed in
   `_work/gh.tl`'s `pull` from `merge_commit_sha` the way `head_sha`
   is parsed from `head.sha`, `""` when absent. `wc -l < _work/gh.tl`
   is 204 and `wc -l < _work/review.tl` is 96.

5. **Tests.** `_work/gitverdict_test.tl` (135 lines) gains
   `test_accept_completes_an_already_merged_pr` and
   `test_accept_refuses_a_closed_unmerged_pr`, both driving the fake
   GitHub the existing tests use. `_work/review_test.tl` (82 lines)
   gains a `merge_sha` case if `Pull` is constructed there.

## Non-goals

- `_work/gitland.tl` is not touched. Its already-merged branch stays
  exactly as it is: it is the path for an item that reached `land`
  before its PR merged, which this change does not eliminate, and
  removing it would strand every item already sitting in `land`.
- No new field on `Item`. The merge sha rides in the commit subject;
  `verdict_head` keeps meaning the head that was JUDGED, not the
  commit that merged.
- `--force` is not added to `verdict`. The verb has none today, and
  the failing-read fallthrough means none is needed.
- A `request changes` or `reject` verdict does not read the PR. Only
  an accept asserts anything about landing.
- No change to the `gitboard-verdict:` verdict-line prefix, to the
  three verdict kinds, to `--enable`, or to the builder-distance
  refusal that runs before this.
- Review distance is unchanged: the accept must still come from a
  non-claimant session, and this runs after that refusal.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverdict_test.tl _work/gh_test.tl
  _work/review_test.tl` ends `test: PASS`, including
  `test_accept_completes_an_already_merged_pr` and
  `test_accept_refuses_a_closed_unmerged_pr`.
- `grep -c 'gh\.' _work/gitverdict.tl` is at least 1 (it is 0 today).
- `wc -l < _work/gitverdict.tl` ≤ 260, `wc -l < _work/gh.tl` ≤ 260,
  `wc -l < _work/review.tl` ≤ 140.
- On a board whose PR is merged, `verdict ID accept --session S`
  leaves the item ended: `gitboard show ID --fields` ends
  `<id8> is completed` and no `phase:` line is printed.

## Enablement

none needed — `gate.handover_refusal` is the precedent for reading a
PR inside a gate, including the `store.has_origin` guard for a
local-only board; `gh.pull` already returns `state` and `merged`; and
`cmd_done` shows exactly what ending an item must do, `rephased_parent`
included. The wrong turn to predict is ending the item WITHOUT
`rephased_parent`, which silently leaves a finished container
de-phased and off every queue; `Change` names it and the container
case is what `_work/gitverbs_test.tl`'s existing
`test_done_returns_a_finished_container_to_plan` already covers for
the `done` path.
