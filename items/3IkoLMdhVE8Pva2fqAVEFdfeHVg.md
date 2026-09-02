## Evidence

`docs/goals.md:7` (origin/main at 2026-09-02) says the paired-comparison
method is "in `skills/work/SKILL.md`":

```
([D25](decisions/d25-outcomes-and-instruments.md), method in
`skills/work/SKILL.md`): each answer is committed on the board as
```

D25 line 28 says the method lives in `skills/work/decompose.md`, and
cosmic-lua/cosmic#1615 (item 3Ikb6WeX) adds the tournament section
there; `skills/work/SKILL.md` describes no method and defers to
`decompose.md` and the tool's help. Reported by #1615's builder, walled
off by that item's Non-goals ("No change to docs/goals.md"). Re-measure
at pull time: `grep -n 'method in' docs/goals.md`.

## Change

`docs/goals.md`: point the "method in" reference at
`skills/work/decompose.md` (the section #1615 adds). One line; no other
prose moves.

## Non-goals

- No change to D25, `skills/work/**`, or the outcome order.
