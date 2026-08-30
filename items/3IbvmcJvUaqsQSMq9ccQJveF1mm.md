## Change

Decided by the operator 2026-08-30: the merge-queue ruleset keeps the
Actions check-run names (`pr / ci|build|repro|smoke`) as the required
checks; the `gate/*` commit-status mirror retires. Background: the
mirror was born the same day as an incident fix (PR #1522 — a lost
`pull_request` run could not be satisfied by a `workflow_dispatch`
re-run, so each gate job posted an event-independent `gate/<name>`
STATUS to the head SHA), and the queue ruleset configured hours later
required the check-run names instead; the operator accepts retiring the
status-based recovery path. Measured 2026-08-30:
`.github/actions/gate-status/action.yml` posts one `gate/<name>` status
per job, invoked from `.github/workflows/pr.yml` jobs `ci` (~line 248),
`build` (~332), `repro` (~420), `smoke` matrix (~507); every line
naming `gate/*`: `pr.yml:20,248,332,420,507`,
`gate-status/action.yml:15`,
`docs/decisions/d38-merge-queue-on-main.md:16,69,73`.

One PR on main:

1. Before deleting anything, grep the whole tree for `gate/` consumers
   outside those measured sites (workflows, `_build/**`, docs). A live
   consumer stops the build — release the claim with the finding.
2. Delete `.github/actions/gate-status/` and its four invocation steps
   in `pr.yml` (and the `pr.yml:20` comment reference).
3. Amend `docs/decisions/d38-merge-queue-on-main.md` per the decide
   skill's amend rule (read `skills/decide/SKILL.md` first): the
   required contexts are the check-run names as configured, the
   `gate/*` mirror is retired with this change, and the PR #1522
   lost-run recovery it provided is superseded — a lost `pull_request`
   run is now recovered by re-running that run, not by a dispatch run
   satisfying statuses. Update the decisions README index row if the
   H1/status grammar requires it.

## Non-goals

No ruleset changes (operator already configured it). No AGENTS.md edit
(item LTMyAU2E owns the AGENTS.md trigger sentence). No changes to
concurrency groups or job content. Item GkZU2EFI (the action's stale
trigger-list comment) is ended by the orchestrator as superseded once
this merges — not part of this diff.
