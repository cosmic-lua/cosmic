## Evidence (from 3I3mjNFi's refinement, 2026-08-19)

AGENTS.md's `## Language and Conventions` section is 149 lines — 30% of
the file — and much of it restates rules that `--make lint` already
enforces mechanically (cast justification, `fallible-returns`,
`find-needle`, file length). The owner's direction on 3I3mjNFi governs:
no prose exemption from the 500-line cap, reclamation before any split,
"prefer making the code explicit over describing it in prose — doctrine
a gate can enforce should live in the gate; the prose that survives is
what a gate cannot say." The module-table reclamation (3I3mjNFi, ~50
lines) lands first; this is the second, doctrinal reclamation.

## Suggested shape

Shrink the section toward the gates: for each block, either (a) the rule
is enforced by a gate → reduce to one line naming the gate and where its
full rule ships (`cosmic --docs guide.lint`, `guide.checking`), (b) the
rule is judgment a gate cannot hold → keep, tightened, or (c) the rule
is enforced nowhere → decide whether it earns a gate (enablement item)
or deletion. G3's win condition already schedules the narrowing
doctrine's death ("the doctrine reduced to a footnote").

This slice also carries the decision record the owner's direction earned
(via the `decide` skill): no prose exemption from the per-file cap;
splitting permitted but reclamation preferred; fewer, shorter docs. The
record belongs with this doctrinal slice, not the mechanical table
deletion.

Attach under 3HyRcrR3 (G9) when plan drains — sibling of 3I3mjNFi.
