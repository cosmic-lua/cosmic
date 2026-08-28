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

## The other half of this defect

`3IYYwdp7` records the same conflation firing the other way. Both rest on
one fact: the guard keys on HAVING HELD THE CLAIM (`_work/flow.tl:433-444`
reads `claim` now and `builders` ever), and claim-holding is a proxy for
authorship that is wrong in both directions.

- **Under-fires — this item.** Writing a spec touches only the `.md`
  sidecar and records nothing, so authorship of a DECISION never
  disqualifies.
- **Over-fires — `3IYYwdp7`.** `item.record_builder` is called on every
  claim-setting move (`_work/gitverbs.tl:251`), so a claim that produced
  a diff nobody is reviewing disqualifies anyway. Measured: `3IUBNQZZ`
  carries `0b13d2b4` in `builders` for PR #1484, which that session
  CLOSED as a duplicate; the diff in review is #1485, written by
  `05f7c552`. Neither session may judge it, and 27 backlog items sit
  behind that and its sibling.

They are siblings, not one item, because they do not share a fix:
re-keying the guard on the artifact under review closes `3IYYwdp7` and
leaves spec authorship as invisible as it is today, while recording spec
authorship closes this one and leaves a discarded build still
disqualifying. A single change keyed on the KIND of participation could
close both — that is a `plan` decision, and whichever item reaches it
first should say so rather than assume it.
