## Change

Measured 2026-08-30 via the effective-rules API
(`GET /repos/cosmic-lua/cosmopolitan/rules/branches/master`): the
branch carries a merge_queue rule (SQUASH, ALLGREEN, 60-minute check
timeout) and a required status check `build` pinned to the GitHub
Actions integration — but `.github/workflows/pr.yml` declares only a
`pull_request` trigger. A queue candidate fires no workflow, so
`build` never reports on it and every queue entry times out after 60
minutes and is ejected: the queue currently blocks all merges to
master. The change, in cosmic-lua/cosmopolitan
`.github/workflows/pr.yml` only: add a `merge_group:` trigger beside
`pull_request`, with a short comment stating why (the queue's
candidates must run the required `build` check; a check run on this
trigger attaches to the candidate's own head). The fix self-tests:
this PR's own merge candidate carries the trigger, so landing it
through the queue IS the verification — a merge that completes proves
the candidate ran `build`.

## Non-goals

No ruleset changes (operator's). No job or step changes. No
concurrency changes. The `build` job is the workflow's only job, so
the required set {build} is already complete once candidates run it.
