A capture whose parent is already decided still costs a full triage
action, because the decision is recorded as PROSE rather than as data.

`gitboard new` takes `--parent ID`, but the plan WIP limit refuses it
when plan is full. A session that has just decided where a capture
belongs and cannot say so falls back to filing it unparented with the
answer written into the spec body. Two items filed that way are on the
board right now, both with the same sentence:

    **Attach this item under `3HyRcW05` (the cast epic), sibling of
    `3I7OygFC`.** It is filed unparented only because `plan` was over
    its WIP limit when the research landed.

- `3IFUa4AY` cast wave 6b
- `3IFUaiGA` cast wave 6c

Measured cost, from the 2026-08-22 scheduled session: of five loop
actions, `next` spent **two** handing out those attaches — one verb
each, transcribing a decision the item itself already carried. No
judgment was exercised. The session ended with `ready` at 0 and triage
still at 11/8, so the two slots came directly out of the drain the
ordering had ranked ahead of everything else.

The shape of the problem: the WIP limit is doing its job (plan should
not absorb work faster than it is refined), but it is also erasing a
decision that was already made, and the erasure is what costs a slot
later. A limit should defer WORK, not discard KNOWLEDGE.

What to decide:

- **Record the intent as a field.** `new --parent ID` under a full plan
  could store the intended parent on the item — unparented, still in
  triage, still counted against nothing — instead of refusing. Triage
  then applies it without re-deriving it. The item file format is the
  contract, so this is a field plus the verb that honours it.
- **Or batch the application.** A `triage --apply-directed` that
  attaches every capture carrying a recorded parent, as ONE action, so
  the loop slot is spent per-decision rather than per-item.
- **Or let `next` skip them.** If a capture's parent is unambiguous
  data, `next` could apply it inline and hand out the next real
  decision, the way it already de-phases a container on `attach`
  without asking anyone.

Which of the three is right depends on whether "the parent was decided
but the limit was full" deserves to be visible on the board as a state
— an argument for the first — or is merely bookkeeping, which argues
for the third.

Not in scope here: changing the plan WIP limit itself. That number
earns a change only through a flow review, and nothing in this evidence
says the limit is wrong — only that its refusal is lossier than it
needs to be.
