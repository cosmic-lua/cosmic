## Change

Adopt GitHub's merge queue on main (decided by the goal owner 2026-08-29; the analysis and the main-only scoping rationale are recorded on closed item 3ISQacGe). The buildable slice, all in the MAIN repo:

1. `.github/workflows/pr.yml`: add `merge_group:` to the `on:` block (measured: triggers are `pull_request`, `workflow_dispatch`, `push` to main at lines 6-8; the concurrency group's `cancel-in-progress` is already scoped to `github.event_name == 'pull_request'` so queue runs never cancel each other). No job changes: the `.github/actions/gate-status` composite posts `gate/*` commit statuses to `github.sha` on every non-pull_request trigger, and on `merge_group` that is the merge candidate's head — verify that claim by reading the composite's SHA expression and state it in a YAML comment beside the new trigger.
2. A decision record in `docs/decisions/` per the decide skill (read `skills/decide/SKILL.md` for the four-section form and the H1 grammar the derived index gates; pick the next free D number by listing the directory): the decision is merge-queue-on-main — accept-time enqueue replaces accept-time merge for main PRs, done's merged-verification only shifts in time, verdict_head keeps meaning the judged head, and board is excluded because direct state pushes land there every few minutes and would thrash a queue.
3. `skills/work/SKILL.md`: in the landing prose, one sentence: a main-repo accept is landed by enabling auto-merge (the queue merges it), while a board PR is merged at accept as before.

## Non-goals

No ruleset/queue enablement (operator-only; until flipped, the trigger is inert and additive). No board machinery changes — cmd_done and verdict_head need none. No orchestration-code changes anywhere (the orchestrator is prose-directed).
