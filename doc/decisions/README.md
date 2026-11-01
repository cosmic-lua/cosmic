# decisions

a decision record keeps a resolved question and its reasons after it leaves
[the roadmap](../roadmap.md). a record states a principle that settles many
cases, not a verdict on one item. a single call that follows from a record or
from [design.md](../design.md) needs no record; its hint or doc says why.

one Markdown file per decision, named `NNNN-slug.md` with the next number.
a record has:

- a status line: `accepted`, or `superseded by NNNN`.
- **context.** what forced the question.
- **decision.** what is done, in the present tense.
- **rejected alternatives.** each with the reason it lost.
- **consequences.** what follows, including what gets harder.

when the decision changes, amend the record to say what holds now. when a new
decision replaces it, the old record's status becomes `superseded by NNNN`.
cite a [design.md](../design.md) promise or principle by name where the record
rests on one.

- [0001 friction triage](0001-friction-triage.md)
