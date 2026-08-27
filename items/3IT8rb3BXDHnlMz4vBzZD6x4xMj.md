## Goal

G6 — the defining paths, ratcheted: the release perf-gate cluster's
board record cites the outcome it actually serves, so review step 5's
parent-chain walk and the derived order stop asserting something
nobody compared.

## Change

Evidence-only slice, no PR (deliverable: the corrections below plus
the recorded answer to where the phantom goal came from).

1. Answer question 1 from the board branch's history: first commit
   introducing "G9 — every release publishes, measured", and its
   propagation path.
2. Correct the `## Goal` line of the two ended sidecars still
   carrying the phantom goal (3ISWHyP7, 3ISlY5Xl), each correction
   naming this item.
3. Re-parent 3ISlY5Xl, 3ISWHyP7, 3ISlWFiS from G3 (3HyRcW05) to G6
   (3HyRcd9F). All three are ended, so the move changes no live band
   and displaces nothing — downward placement is not the protected
   direction (`skills/work/SKILL.md`, "a comparison that RAISES work").

## Non-goals

No change to docs/goals.md (G9 there — "the least tree that keeps
its promises" — is correct as written). No edits to 3ISlWFiS's spec
(already corrected, commit 31390593). No new comparisons: the three
inherit G6's placement through the parent edge only.

## Acceptance

- `grep -rln "every release publishes" items/` names no OPEN item's
  sidecar (only ended 3ISWHyP7/3ISlY5Xl with the correction note, and
  this capture quoting it as evidence).
- `gitboard show 3ISlY5Xl | grep parent:` → 3HyRcd9F (same for
  3ISWHyP7, 3ISlWFiS).

## Enablement

none needed — attach and spec are existing verbs; the history read is
plain git.

## Result

Question 1 answered from the board branch's own history
(`git log --all -S "every release publishes, measured" -- items/`):
the phrase was INVENTED in 3ISWHyP7's spec (commit 4e788163,
2026-08-26T17:19:36Z) and propagated by copy to 3ISlY5Xl (cd99c9fc,
19:50). It never appeared in docs/goals.md. The third item, 3ISlWFiS,
had already been corrected to cite G6 (commit 31390593, 21:49), which
cut the propagation vector; no OPEN item carries the phrase.

Question 2 performed rather than escalated, per the Change's clause 3
reasoning: `attach 3ISlY5Xl|3ISWHyP7|3ISlWFiS 3HyRcd9F` done, and
both stale `## Goal` lines corrected in place with a note naming this
item.

Follow-up seeded: none needed — review step 5's guard now reads the
right outcome for all three, and the copy-source is corrected.
