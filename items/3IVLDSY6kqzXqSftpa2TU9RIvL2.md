# Problem

The board has no way to encode that an outcome now HOLDS. Roots are
never phased, so the container closure path (last child ends, parent
returns to backlog, session verifies and ends it) never applies to an
outcome root; `gitboard done` will end any item, but nothing verifies
a win condition first, nothing carries the evidence, and nothing
updates `docs/goals.md`, whose prose the board's order is supposed to
mirror. The effect on the derived order is also unspecified: the order
is transitive closure over compare edges, and ending a root that
carries edges (G4 today: `[>3]`, edges up and down) may sever chains
that placed other items — untested in `_work/gitgraph_test.tl`
(measured 2026-08-27: no test ends a compared root).

This is now blocking a real decision: G9's machinery is built (per-PR
`_build/public_surface_test.tl`, per-release `_build/size.tl` wired
into release.yml), G4 is prose-designated "near holding", and G5 is
two items from its stated win condition. When the first one is judged
held, intake must walk past it to the next-ranked outcome without a
hand edit.

# Change

Settle and build the holding procedure:

- a VERIFICATION item form: an item under the outcome whose spec runs
  each `measured by:` command from goals.md and quotes the evidence;
  its acceptance is the win condition, quoted. It flows plan → ready →
  do → check like any slice, so a session that did not do the goal's
  work judges the claim.
- what "held" IS on the board: ending the root (`done --reason
  completed`) vs a marker intake skips. Decide in plan; whichever way,
  the derived order must stay total for the remaining roots (add the
  gitgraph test for ending/skipping a compared root), and a held
  outcome's gates keep enforcing it — new evidence files under it and
  REOPENS it rather than under a lower goal.
- the goals.md amendment: held outcomes move to a "holding" section
  with the verification date and evidence link; the tradeoff behind
  the mechanism is a decision record (the `decide` skill).
- skills/work: SKILL.md and decompose.md name the procedure where
  intake is described.

# Non-goals

- Judging any specific goal held (G9's verification is its own item,
  blocked on this one).
- Retuning the outcome order or re-asking comparisons.

# Acceptance

- a gitgraph test covers the derived order when a compared root is
  ended (or marked held): every remaining root still has a position.
- skills/work documents the verification-item form and the intake
  behavior at a held root.
- a decision record states the tradeoff (end vs mark; reopen rule).
