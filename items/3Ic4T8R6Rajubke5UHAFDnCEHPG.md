## Change

Evidence (review of PR #1540, 2026-08-30): after the gate-status
mirror's removal, nothing in `.github/workflows/pr.yml` posts a
commit status, but the workflow still grants
`permissions: statuses: write`. The change, one line in
`.github/workflows/pr.yml`: remove the `statuses: write` grant.
Before removing, prove it dead: `grep -n 'statuses' .github -r` and
`grep -rn 'statuses' _build/` on your branch head must show no
surviving consumer (a POST to the statuses API, an action that needs
the scope); paste the greps in your report. CI's five lanes green on
the PR head is the acceptance — no test exists for workflow
permissions.

## Non-goals

Nothing else in pr.yml moves — no triggers, jobs, steps, concurrency,
or other permission lines.
