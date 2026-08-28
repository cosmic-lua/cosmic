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

## Third instance, 2026-08-28 — and the first two were not the whole pattern

`3IWJ2cHm` passed `gitboard check` with only ONE reported problem (an
empty `## Enablement`) while BOTH `## Change` and `## Acceptance` read
"not yet specified" / "to be specified". The gate counted them as
present, so an item whose entire buildable content was two placeholders
was one section away from a green check.

That is the same failure as the original report, but it sharpens the
shape in two ways.

**It is not confined to `## Acceptance`.** The first report framed the
fix around Acceptance promising runnable commands, and noted a section
with no command in it fails on its own terms. `## Change` carries no
such self-evident test — it promises a decided shape, which is not
mechanically checkable — yet it failed here in exactly the same words.
A rule keyed to Acceptance alone would have passed this item.

**The deferral phrases are stable across authors and weeks.** Three
instances now: "To be written at refinement", "the shape and the files
to touch are to be settled at plan", "not yet specified" / "to be
specified". A short phrase list would have caught all three, which is
weaker than a contract check but is not nothing, and is cheap enough to
land while the contract question is still open.

**The cost is measurable and repeats.** Each instance spends a
refinement pass discovering the item is not what the gate said it was.
Here the refiner had been dispatched to write one missing section and
had to rewrite two more; on `3IUBNQZZ` an earlier instance cost a full
pull, a build, and a bounce.

Worth noting what did NOT fail: in all three cases the human-shaped
check — a session actually reading the sidecar — caught it immediately.
The gate is the only thing that was fooled, which is an argument for
making the gate's answer less trusted rather than only for making it
smarter. A `check` that printed which sections it merely found NON-EMPTY,
as against which it verified, would close the misreading without needing
to settle what a section promises.

## Fourth instance — and it defeats the phrase-list fix

`3IWMDe1R`, same day. `check` again reported only the empty
`## Enablement`, while `## Acceptance` read "To be set at refinement."
and `## Change` opened:

    Refine before building: decide which…

That second one matters more than another tally mark. Every prior
instance used a deferral PHRASE — "to be written", "to be settled",
"not yet specified" — and the note above proposed a short phrase list as
the cheap partial fix. **This one would pass such a list.** It reads as
an ordinary imperative sentence; what makes it a placeholder is that its
verb is a RESEARCH verb, and the section it heads is supposed to state a
decided shape.

So the blocklist is not merely weaker than a contract check — it is
defeated by the fourth instance in the sample it was proposed from. That
is worth knowing before anyone builds the cheap version and calls the
class closed.

The contract framing survives intact and is now the only candidate left:
`## Change` promises a decided shape, and a section instructing the
reader to decide is failing that promise on its face.
