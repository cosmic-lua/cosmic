# 0001 friction triage

status: accepted

## context

users and agents send friction logs, such as the notes of an app built on
cosmic. the promise of efficiency (promise 2) measures a builder's friction,
so a note is evidence, but a note may also be wrong, stale, or ask for
something a promise forbids.

## decision

verify each note against the current tree, reproducing it where possible.
classify it as one of: bug, misleading message, doc gap, misunderstanding the
docs invited, design choice, or feature request.

answer in this order, following principle 8 ("an error-site hint beats a
gotcha doc beats guide prose"):

1. fix a bug.
2. make the error site say the fix.
3. write a doc.
4. add a feature, only when the first three do not meet it, judged against
   principle 5 ("the least tree that keeps its promises") and the promises.

friction is valid when it slows a builder, unless meeting it breaks a promise
or principle. that friction is answered with a hint at the error site saying
why, not with a change. a design choice that stands gets such a hint.

general rules the answers apply:

- a narrowing is sound or absent (promise 1, no silent bugs): it is not kept
  where the checker cannot show the variable unchanged, and the hint names the
  rebind that is sound.
- a guide suffices until several apps vendor its code (principle 5); then a
  module is considered.
- no helper drops a failure (principle 3, honest returns): a convenience
  returns its failure or raises, and a hint shows the sanctioned form.
- grammar grows only where it removes boilerplate without opening an escape
  hatch (principle 4): the new form is fully checked, never a cast or a tuple.

## rejected alternatives

- accept every note as a change request: it grows the tree against principle
  5 and trades a promise for a convenience.
- answer a design choice with a decision record per item: the records bury the
  few that state a principle. the hint is what the builder meets.

## consequences

a rejected request still leaves the builder a hint at the point of friction.
a reviewer of a friction fix checks the answer's rank in the order above.
