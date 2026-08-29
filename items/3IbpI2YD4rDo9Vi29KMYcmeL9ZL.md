## Change

REWORKED 2026-08-29 after the operator checked the ruleset UI: "Require merge queue" is NOT offered — whilp/cosmic is a personal-account repository and the merge queue remains an organization-only feature (public org repos, or private on Enterprise Cloud). The adoption is DEFERRED, not adopted. The buildable slice shrinks to one artifact in MAIN:

1. `docs/decisions/` — the D38 record's content flips to document the evaluation and the deferral: the base-update re-run tax (measured in kind on closed item 3ISQacGe), the adoption surface that was prepared and verified (a `merge_group` trigger composes with the gate-status composite's `github.sha` fallback; accept-time enqueue via auto-merge; done and verdict_head unchanged; main-only scoping since board's direct state pushes would thrash a queue), the blocking fact (unavailable on personal-account repos), and the revisit condition (migrating the repo to an organization — a decision with costs beyond CI that is nobody's to make in passing). Keep the decide-skill form and whatever status value the index grammar uses for a decision that defers/rejects — read skills/decide/SKILL.md.
2. REMOVE from the PR: the pr.yml `merge_group` trigger and the skills/work/SKILL.md landing sentence — no behavior or doc may describe a capability the repo cannot enable; the record alone carries the prepared surface for revival.

## Non-goals

No org migration advocacy in the record — state the revisit condition neutrally. No workflow changes. No skill changes.
