`gitboard check` reports an item meets the ready bar when a required
section's body is a placeholder saying it has not been written. The bar
checks that the heading exists and the section is non-empty; it does not
check that the section says anything.

Observed 2026-08-27 on `3IUBNQZZ` ("codec compare rows are state-split").
`gitboard check 3IUBNQZZ` returned `meets the ready bar`, so `next`
offered it as a pull. The item's `## Acceptance` section read, in full:

    To be written at refinement, with the derivation command and its
    measured output quoted.

The Acceptance commands ARE the definition of done, so an item with none
cannot be implemented from its spec alone — which is the whole property
the bar exists to certify. The puller built the tree, re-measured, found
two further deferrals in `## Change` ("the shape and the files to touch
are to be settled at plan", which plan did not settle) and a data source
the spec assumes exists but does not, then correctly bounced the item to
`plan` with no diff. The bounce worked; the bar should have caught it
first.

The failure is cheap to describe and cheap to fix: a required section
whose body matches a deferral phrase — "to be written", "to be settled",
"TBD", "at refinement", or a body that is only a placeholder sentence
with no command in a section that must carry commands — is not a
satisfied section. `## Acceptance` is the strongest case because its
contract is specifically "runnable commands with expected output": a
section with no command in it fails on its own terms, and that check
needs no phrase list at all.

Worth considering as the general shape rather than a blocklist: check
each required section against what that section PROMISES. Acceptance
promises commands. A phrase blocklist catches this instance; a
contract check catches the class.

Evidence that this is not a one-off: the same pull also found `## Change`
deferring its own shape to a plan step that had already happened. Two
required sections in one item passed the bar while explicitly declaring
themselves unfinished.
