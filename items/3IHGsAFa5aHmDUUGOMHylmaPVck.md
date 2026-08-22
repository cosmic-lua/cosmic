## Goal

G8 — the ready bar. A spec whose Non-goals forbid what its Acceptance
gate enforces cannot be implemented without violating one of them, and
the contradiction is invisible until a builder or reviewer collides
with it.

## Evidence

3IBFBWtc (fuzz corpus persistence), bounced 2026-08-20 and again
2026-08-22: its Non-goals forbade a .cosmic-coverage row for the new
module while Acceptance #1 demanded `bin/cosmic --make ci` end
`ci: PASS` — and the coverage stage's file-set drift check forces the
row, so both could not hold. The item's own spec records the lesson:
"a Non-goals bullet that forbids touching a generated or ratcheted
file has to be checked against what the Acceptance gate actually
enforces, because the gate wins." The contradiction was introduced by
the pass that bounced PR #1297 — a review fix creating the next
bounce, which is what makes this a bar gap rather than one item's
typo.

## Direction

One paragraph in decompose.md's ready bar: before `move ID ready`,
read each Non-goals bullet against the gates Acceptance invokes — a
Non-goal that forbids a file a named gate regenerates or ratchets is
a contradiction to resolve in the spec, not a wall to leave standing.
Optionally mechanical later (a check that flags Non-goals naming
gate-owned paths), but the prose rule alone would have caught both
bounces.
