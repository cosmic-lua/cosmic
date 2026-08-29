## Change

ADOPT, re-decided 2026-08-29: the earlier deferral's blocking fact is
cleared — the merge queue is a GitHub feature restricted to
organization-owned repositories (public repos on any plan, private on
GitHub Enterprise Cloud), and whilp/cosmic moved to the cosmic-lua
organization on 2026-08-29 (measured: `git -C . remote -v` on every
session checkout now names https://github.com/cosmic-lua/cosmic). The
PR carries the adopt shape, three artifacts plus one repair in the file
it already touches:

1. `.github/workflows/pr.yml` — a `merge_group:` trigger alongside
   push/pull_request/workflow_dispatch, with the comment noting
   gate-status's SHA expression
   (`github.event.pull_request.head.sha || github.sha`) already
   resolves to the queue candidate's head on this event; no job
   changes.
2. `docs/decisions/d38-merge-queue-on-main.md` (+ the README.md index
   row) — the decision record, status active, decide-skill form. Its
   context section additionally records the enabling fact, inserted
   after the existing context prose and before the **decision:** line:
   the queue is restricted to organization-owned repositories
   (public on any plan, private on GitHub Enterprise Cloud) —
   unavailable on personal-account repos — and whilp/cosmic moved to
   the cosmic-lua organization on 2026-08-29, which is what cleared
   the way to enable it here.
3. `skills/work/SKILL.md` — one landing sentence in the two-states
   section: a main-repo accept is landed by enabling auto-merge (the
   queue merges), while a board PR merges at accept as before.
4. `skills/work/SKILL.md` — the two stale repo-owner references in
   this same file update to the cosmic-lua organization: line 17
   whilp/cosmopolitan → cosmic-lua/cosmopolitan, line 27 whilp/cosmic
   → cosmic-lua/cosmic (measured on the PR head:
   `grep -n whilp skills/work/SKILL.md` → exactly those two lines;
   both checkouts' remotes now point at cosmic-lua).

The ruleset flip itself (queue enabled on main, squash method,
required contexts gate/ci, gate/build, gate/repro,
gate/smoke-macos-latest, gate/smoke-windows-latest) is the operator's
action, outside this PR; until flipped the merge_group trigger is
inert and additive.

## Non-goals

No workflow job changes; no gitboard code changes; no org-migration
advocacy in the record beyond the enabling fact stated neutrally. The
repo-wide owner-rename residue outside skills/work/SKILL.md (notably
bin/cosmic.pin and other whilp/* references across the tree) is a
separate item, not this diff.
