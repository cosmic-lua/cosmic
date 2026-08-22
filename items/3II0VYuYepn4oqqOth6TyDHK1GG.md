An Acceptance grep can pass without discriminating anything, and the
ready bar's "measured, not inferred" rule does not catch it.

## Evidence

The spec for 3ICDNJmQ, written 2026-08-22, carried this Acceptance
line:

    `grep -c 'sha = ' _work/gh.tl` is at least 1 (it is 0 today).

The parenthesis is the measurement the bar asks for, and it was
WRONG. On the pre-change file the count is 4, verified with
`git show origin/board:_work/gh.tl | grep -c 'sha = '`, because
`grep -c` counts matching LINES and `pull()` already contained
`local sha = ""`, `sha = tostring(head["sha"] or "")`,
`head_sha = sha,` and `merge_sha = ...`.

The threshold ("at least 1") passed before the change was written and
after, so the command witnessed nothing. It was caught by the
implementing agent reading the spec, not by any gate: `gitboard
check` lints that Acceptance is present and non-empty, never that its
commands discriminate. The sibling line in the same spec,
`grep -c 'blocks_land' _work/gitland.tl` is 1, does discriminate
(0 before, 1 after) — so the spec contained one live check and one
dead one, indistinguishable by shape.

## Why it might matter

This is the "acceptance by vibes wearing digits" anti-pattern
(decompose.md) in the form the bar was written to prevent, surviving
the bar. A dead grep is worse than no grep: a reviewer reads a number
and a claim, both true, and concludes the change is witnessed.

Same family as 3IHGsAFa (a Non-goals bullet contradicting what the
Acceptance gates enforce) — both are specs whose sections are
individually well-formed and jointly wrong, which is exactly what a
presence-and-non-emptiness lint cannot see.

## Directions, not a decision

- Refinement states the BEFORE and AFTER of every count, and a
  refresher at pull re-runs the before. A before that already equals
  the after is a dead check by construction.
- Mechanically: a grep-shaped Acceptance line whose stated before and
  after are equal is refusable at `move ID ready`, which needs the
  spec to state both — a grammar change to the bar, not just a lint.
