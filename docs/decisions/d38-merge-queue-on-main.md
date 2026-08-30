# D38 — main lands through a GitHub merge queue; board keeps merge-at-accept

- **date:** 2026-08
- **status:** amended 2026-08 (gate/* mirror retired)
- **context:** the orchestrator lands a main-repo PR by merging it at
  accept time; `done` then re-reads the PR and verifies it actually
  merged before ending the item (`_work/gitverbs.tl` `cmd_done`, gated
  on `review.blocks_land`). when main moves while a PR waits, that
  merge is refused, the branch updates, and the whole `pr.yml` gate
  re-runs — a ~4-5 minute tax per landing at parallel hours, paid
  again for every PR the update invalidates. research item 3ISQacGe
  characterized the fix (GitHub's merge queue serializes the re-runs
  instead of repeating them per PR) and, by fiat from the goal owner
  on 2026-08-29, decided ADOPT scoped to main. that item also read the
  machinery this decision depends on: `.github/actions/gate-status`
  already posts `gate/*` commit statuses to `github.event.pull_request.head.sha
  || github.sha`, and on a `merge_group` event there is no
  `pull_request` payload, so the expression falls back to `github.sha`
  — the merge candidate's own head, the same fallback `push` and
  `workflow_dispatch` already rely on. the concurrency group's
  `cancel-in-progress` is already scoped to
  `github.event_name == 'pull_request'`, so queue runs never cancel
  each other. board, by contrast, receives direct state pushes every
  few minutes from concurrent agents; queuing those would serialize
  work the queue exists to parallelize instead. the queue is a GitHub
  feature restricted to repositories owned by an organization (public
  repos on any plan, private repos on GitHub Enterprise Cloud) —
  unavailable on personal-account repos. whilp/cosmic moved to the
  cosmic-lua organization on 2026-08-29, which is what cleared the way
  to enable it here.
- **decision:** enable a GitHub merge queue ruleset on `main`, and land
  main-repo PRs through it:
  - `pr.yml` gains a `merge_group:` trigger alongside `push`,
    `pull_request`, and `workflow_dispatch`, so the gate runs on each
    queued merge candidate. no job changes: `gate-status`'s SHA
    expression already resolves to the candidate head on this trigger.
  - a main-repo accept is landed by enabling GitHub auto-merge on the
    PR instead of merging it directly; the queue performs the merge
    once its own gate run is green.
  - `cmd_done`'s merge verification is unchanged in code: it already
    re-reads the PR and blocks until `merged` is true, so under the
    queue that check is satisfied later rather than differently —
    the tax it used to pay per repeated `pull_request` re-run becomes
    one serialized re-test the queue owns.
  - `verdict_head` keeps its existing meaning: the head the reviewer
    judged. the queue may test that head merged onto a newer `main`
    before landing it, but the recorded verdict still names what was
    reviewed, not what the queue produced.
  - board is excluded: its own branch takes direct state pushes every
    few minutes from concurrent agents, and queuing those would
    serialize work the two-state system (D37) is built to run
    concurrently. board PRs keep merge-at-accept.
- **rejected:**
  - **queue both main and board.** board's write pattern is frequent
    direct pushes to its own branch, not PR merges contending for a
    shared base the way main's PRs do — there is no re-run tax on
    board to recover, and a queue there would add latency without
    removing rework.
  - **change `cmd_done` or `verdict_head` semantics to fit the
    queue.** both already express what remains true under a queue:
    `done` verifies a merge happened, at whatever time it happened,
    and `verdict_head` names the reviewed head, not the landed one.
    rewriting either would be motion with no defect behind it.
  - **keep merging at accept and eat the re-run tax.** the tax is
    real and recurring — 3ISQacGe measured it in kind (a second
    `pull_request` run on every merge-base update) — and a queue
    serializes exactly that class of rework into one re-test per
    queued batch instead of one per invalidated PR.
- **consequences:** `pr.yml`'s required `gate/*` contexts are satisfied
  by queue runs with no composite-action change. the orchestrator's
  landing step becomes repo-conditional: enable auto-merge on a
  main-repo accept, merge directly on a board PR. the ruleset itself
  (queue enabled, squash method, `gate/*` contexts required) is an
  operator action outside this record and outside gitboard — until an
  operator flips it, the `merge_group` trigger is inert and additive,
  so this record lands ahead of that flip rather than depending on it.
  revisit if board's write pattern changes to PR-based landing (the
  exclusion would need re-justifying) or if the queue's own latency
  under this repo's gate runtime (~2 minutes ci, up to 25 minutes
  cold) turns out to serialize landings slower than the tax it
  replaced.
- **amended 2026-08 (gate/* mirror retired):** the operator configured
  the merge-queue ruleset to require the Actions check-run names
  (`pr / ci|build|repro|smoke`) rather than the `gate/*` commit-status
  mirror this record's context and consequences described.
  `.github/actions/gate-status` and its four invocations in `pr.yml`
  are deleted; nothing posts a `gate/*` status any more. The PR #1522
  lost-run recovery `gate-status` provided is superseded: a lost
  `pull_request` run is now recovered by re-running that run, not by a
  `workflow_dispatch` run satisfying an event-independent status.
