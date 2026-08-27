PR #1425's review surfaced a board-hygiene drift: items whose Goal
prose names G8 (the flow system, root 3HyRdT1J) or other non-type
outcomes sit parented under 3HyRcW05 (G3 — an honest type layer),
which is the top-ranked band, so they inherit a priority their
outcome does not hold. Observed instances 2026-08-27: 3ISUA9aR
(claim-abandon guard, Goal says G8, completed under G3); the release
lane repairs 3ISWHWQT/3ISWHyP7 (G6 work filed under G3, both
completed); earlier bisect items in the same family. The fix is a
triage sweep: `gitboard tree` under 3HyRcW05, read each open item's
Goal line, and `attach` the mismatched ones under the root their
prose names — re-parenting is reversible and placing lower asserts
nothing, but a comparison that would RAISE an item is the goal
owner's. Completed items stay where they died (history, not state).
Worth doing before the next flow review, whose per-band numbers read
placement.
