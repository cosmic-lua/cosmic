## Evidence

`builders` records who PULLED an item, so `next` correctly withholds a
verdict on work a session implemented (3IE6ttNh). It does not record who
wrote the item's SPEC. A `spec` commit touches only the `.md` sidecar and
adds nothing to the item record, so a session that decided what an item
should be is later offered its own decision to judge.

Observed 2026-08-28 on 3IVF3HbV. Session 05f7c552 wrote spec text
settling a contested route (commits 8621e558, cc377d8d, 9bea9105),
including the sentence "The pick is route 3 of the three above: split".
Hours later `gitboard next` offered that same session the review of
PR #1480. `grep -c '05f7c552' items/3IVF3HbV*.tl` returns 0 — the board
had no record of the involvement, and the guard passed. The session
declined by hand after checking `git log` on the sidecar; nothing in the
tool would have stopped it.

This is narrower than 3IE6ttNh's claim overwrite: the claim machinery
works. The gap is that authorship of a DECISION is invisible where
authorship of an IMPLEMENTATION is not, and review distance is supposed
to cover both — review.md's rule is that the reviewer did not produce
the thing being judged.

Note the case is not symmetric with a bounce. A reviewer who returns an
item to `plan` and names a gap is performing review, not authorship;
recording that as a builder would wrongly bar the reviewer from judging
the rework, which review.md expects them to do. Whatever is recorded has
to separate "I wrote what this item should be" from "I judged it".

## Why it matters

The distance is the system's final gate, and this is the one hole in it
that leaves no trace to audit after the fact. A session cannot discover
the conflict from `gitboard show`; it has to think to run `git log` on
the sidecar and read what it finds there.
