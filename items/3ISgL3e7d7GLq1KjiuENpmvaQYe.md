Every accepted PR in `land` is unmergeable today because its
`pull_request`-event workflow run is stuck in a pre-queued limbo that
GitHub will neither start, re-run, nor cancel, so the ruleset's
required `build` check stays "expected" forever.

Observed 2026-08-26 ~16:40–16:55 UTC against `whilp/cosmic`, on all
three items sitting in `land`:

- 3ISWHWQT / PR #1415 (head `e3ccf1b`), 3ISNVQBg / PR #1412 (head
  `7ff1260c`), 3IOCd5xW / PR #1413 (head `57107433`).
- Each head carries five SUCCESSFUL check runs — `ci`, `build`,
  `repro`, `smoke (macos-latest)`, `smoke (windows-latest)` — posted
  by a `workflow_dispatch` run of the same `pr.yml`.
- `PUT /repos/whilp/cosmic/pulls/<N>/merge` nonetheless returns
  `405 Repository rule violations found: Required status check "build"
  is expected.` for all three. `mergeable_state` is `blocked`.
- The stuck runs: #1413's `pull_request` run `32985995623` (queued
  since 15:44 on the current head), #1412's `32986001847`, #1415's
  `32985764676`. They are casualties of the ~15:28–16:00 UTC GitHub
  runner incident already noted in #1415's review comment.
- The Actions API refuses every remedy on them:
  `cancel` → `409 Cannot cancel a workflow run that has not been
  queued yet`; `rerun` → `403 This workflow is already running`. A
  re-run of one of them (`32985915525`) went straight back to `queued`
  and produced no jobs.

So a `workflow_dispatch` run's green checks do NOT satisfy the
ruleset, and the only lever that would — a fresh `pull_request` event
superseding the stuck run via the workflow's `cancel-in-progress`
concurrency — needs a push to the branch or a close/reopen, both of
which the operating rules forbid as CI-kicking.

Two things this is evidence for, either of which could be the slice:

1. **The lane has no recovery path a session may take.** When a
   `pull_request` run is lost, a session can re-run CI but cannot make
   the result count. Options worth weighing: allow a
   `workflow_dispatch` run of `pr.yml` to satisfy the ruleset (e.g. by
   having the gate publish a commit status the rule names, rather than
   relying on the job name); or narrow the required set to a single
   aggregating check the dispatch lane also posts.
2. **`gitboard land` inherits the stall.** `land` refuses until the PR
   is merged, and nothing on the board records "merge blocked by the
   forge". Three items sat in `land` across a whole session with no
   way to move and no trace of why. Whether the board should carry a
   blocked-on-forge state, or whether that is deliberately outside it,
   is the question.

Cost of leaving it: #1415 is the release-lane fix — release.yml has
been unable to publish since this morning's schedule run — so the
stall is holding the release lane down as well as the board's `land`
column.
