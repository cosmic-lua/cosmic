## Evidence

`next` at 16:0x offered «fh4n_DtCK» as "accepted, awaiting merge —
finishing beats starting" (`_work/action.tl:188`) while its PR (#374)
was already in cosmopolitan's merge queue: a direct merge returned
`405 Pull Request is in the merge queue`; it merged on its own at
16:23. Every `next` in between offered the same unactionable head, and
an orchestrator following the doctrine ("do what next names") had
nothing to do but poll. Both repos merge through a queue (#1655 was
`pull_request.enqueued` at 17:37 after its accept).

## Change

`_work/action.tl` (and `flow.tl` where the stage derives): when the
accepted item's PR reports auto-merge enabled or `mergeable_state ==
"queued"` (the `gh.tl` PR read already carries the fields the verdict
verb reads), render the item as `queued` — listed under doing, never
offered by `next` as the head — and let `next` fall through to the
next actionable item. A `queued` item that leaves the queue without
merging returns to "awaiting merge". `done` is unchanged.

`_work/flow_test.tl` / `action_test.tl`: a fixture PR with
`auto_merge` set is not offered; one without it is.

## Non-goals

No polling, no new verb; the state is read when `next` reads the PR.
