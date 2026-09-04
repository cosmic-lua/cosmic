## Evidence

Found during review of board item `3Ip8vSUaCOwaFZxufNBeDVeUY1D` («eDVe_UY1D»,
merged PR cosmic-lua/cosmic#1673, `check.swap_members`). One inline comment
it added violates `skills/docs-style/SKILL.md`'s own rule and worked
example — no decision-record citations in code comments, state the rule
standalone instead:

`cosmic/check.tl:167` (post-merge):
```
if not ok then error(caught, 0) end -- throws: rethrows body's error after restoring members (D23)
```

`docs-style`'s own worked example is this exact pattern:
`-- return may carry the value and nothing else (D20 rule 11).` →
`-- A fallible return has exactly two slots: the value and the error.`
(drop the citation, state the rule in place).

`git grep -n '(D[0-9]' cosmic/**/*.tl` (or equivalent) confirms this is the
only decision-citation inside any inline code comment in `cosmic/`; every
other `-- throws:`/`-- assert:` marker in the tree (e.g. `searcher.tl`,
`hash.tl`, `teal.tl`, `coverage/init.tl`) states its rationale standalone,
with no `(D<N>)` reference.

## Change

`cosmic/check.tl:167`: reword the trailing `-- throws:` comment to state
why `swap_members` may throw (per D23: `check` module functions are
permitted to throw) without citing the decision record by number — e.g.
`-- throws: check may throw; rethrows body's error after restoring members`.

## Non-goals

Not a broader audit of `docs-style` compliance across the tree beyond this
one site — found incidentally during a different item's review, not from
a systematic sweep.
