# 0001 friction triage

status: accepted

## context

users and agents send friction reports, such as the notes of an app built on
cosmic. the promise of efficiency (promise 2) measures a builder's friction,
so a report is evidence. it may also be wrong, stale, or ask for something a
promise or principle forbids.

## decision

verify each note against the current tree, reproducing it where possible. a
note that does not reproduce is reported as fixed or stale, with the evidence,
and changes nothing.

classify the note and answer it:

- bug: fix it (promise 1, no silent bugs).
- misleading message: correct the error site so it says the fix.
- doc gap: write the doc.
- misunderstanding the docs invited: add the hint or doc that would have
  prevented it.
- design choice: add a hint at the error site that explains it.
- feature request: add a feature only when none of the answers above meets
  the need, and judge it against principle 5 ("the least tree that keeps its
  promises") and the promises.

a hint is preferred to a doc because principle 8 says "an error-site hint
beats a gotcha doc beats guide prose". principle 8 orders only those two.
fixing a bug first follows from promise 1, and a feature last from principle 5.

friction is valid when it slows a builder. friction that cannot be met without
breaking a promise or principle is still answered, with a hint at the error
site saying why, and not with a change.

the rules below are corollaries of the promises and principles cited, not new
principles:

- a narrowing is sound or absent (promise 1, no silent bugs): it is not kept
  where the checker cannot show the variable unchanged, and the hint names the
  rebind that is sound.
- no helper drops a failure (principle 3, honest returns): a convenience
  returns its failure or raises, and a hint shows the sanctioned form.
- grammar grows only where it removes boilerplate without opening an escape
  hatch (principle 4, no escape hatch in the type layer): the new form is fully
  checked, never a cast, and a function never returns a bare tuple (principle
  3).
- a guide suffices until the same code is copied into several apps; then a
  module is considered under principle 5. this threshold is this record's own
  rule.

## rejected alternatives

- accept every note as a change request: it grows the tree against principle
  5 and trades a promise for a convenience.
- answer a design choice with a decision record per item: the records bury the
  few that state a principle. the hint is what the builder meets.

## consequences

a declined request still leaves the builder a hint at the point of friction.
a reviewer of a friction fix checks the answer against the list above.
