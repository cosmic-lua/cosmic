## Change

Refreshed 2026-08-29 against the two-state board (the original
evidence below reasons about the deleted `land` column; the incident
evidence stands, the board half is retired — today an accepted item
simply cannot reach `done` until the merge succeeds, which is the
correct surviving behavior and needs no new state).

The surviving slice is the recovery path: make a re-run CI able to
satisfy the ruleset when the original `pull_request` run is lost.
Measured 2026-08-29: `.github/workflows/pr.yml` triggers on
`pull_request` AND `workflow_dispatch` (lines 6-8, `grep -n`), so a
dispatch re-run already produces green check runs — the incident
proved those do not satisfy the required check ("Required status
check 'build' is expected" while five dispatch-run checks sat green
on the head).

The change, in `.github/workflows/pr.yml` on main:

1. Each of the four required jobs (`ci`, `build`, `repro`, `smoke`)
   gains a final step that POSTs a commit STATUS to the head SHA via
   the statuses API (`POST /repos/:owner/:repo/statuses/:sha`,
   `GITHUB_TOKEN`, context `gate/<job>`, state from the job's
   outcome — post failure too, from an `if: always()` step, so a red
   run marks the commit red rather than leaving "expected"). Commit
   statuses attach to the SHA regardless of which event triggered
   the workflow, which is exactly the property check runs lacked in
   the incident.
2. A test is not runnable for workflow YAML; the diff's proof is one
   dispatch run on the PR's own head showing the `gate/*` statuses
   appear on the commit (the builder runs the dispatch and reads the
   statuses API back — command and output re-run by the reviewer).
3. The admin half is NOT this diff: switching the ruleset's required
   contexts from the job check runs to the `gate/*` statuses is a
   repo-settings change only the operator can make. The PR
   description states the exact before/after required-context list
   as the ask; until the operator flips it, the statuses are
   additive and change nothing.

## Non-goals

No board machinery changes (the `land`-column half of the original
evidence is retired with that column). No workflow behavior changes
beyond the added status posts — triggers, jobs, gates untouched. No
close/reopen or empty-commit CI kicking, ever.
