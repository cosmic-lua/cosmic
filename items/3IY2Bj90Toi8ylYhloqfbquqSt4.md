## Change

The distance guard: a session that built or specced an item is never
offered — and cannot record — its verdict, and no session holds two
live claims. Reads the involvement record the blocking sibling
(3IVCd39E's re-spec) lands; blocked on it.

Measure at pull time, after the sibling lands:

1. Review-claim derivation (`_work/gitverbs.tl` cmd_take's
   take_review branch) additionally refuses when `session` appears
   in `it.builders` or `it.speccers`:
   `REFUSED: <session> built/specced <id8> — the verdict needs a
   fresh context`. The refusal logic lives in `_work/gitgate.tl`
   (291 lines, room) as one predicate both callers share.
2. `_work/gitverdict.tl`: the same predicate refuses recording a
   verdict when the recording session is in builders/speccers, with
   `--force --why` as the repair escape (audited in the log via the
   existing forced_suffix grammar).
3. One live claim per session name: a take that would CLAIM an item
   (not a review-claim, not a re-take of the session's own item)
   refuses when the session already holds a live claim on another
   open item: `REFUSED: <session> already holds <other-id8> — one
   claim per worker; drop it or finish it first`. This is the
   collision alarm 3IMk60ar's remaining half asked for: two runners
   sharing a name now collide loudly at the second take instead of
   silently corrupting mutual exclusion.
4. `_work/action.tl`: next_action's review offer applies the same
   builders/speccers exclusion, so `next` never offers what take
   refuses (the lesson PR 1523 already taught this machinery once).
5. Tests: builder-cannot-review-claim (derivation steps past to the
   next candidate), speccer-cannot-review-claim, verdict refusal for
   builder and speccer, forced verdict records with the forced
   suffix, second-claim refusal (and: a re-take of the session's OWN
   claimed item still succeeds — rework handovers depend on it; and
   a review-claim while holding a build claim still succeeds — the
   orchestrator pattern depends on... NO: verify against the skill:
   a review subagent names ITSELF uniquely, so a review-claim
   coexisting with a build claim under one name is not a supported
   pattern; decide from the skill's text and pin whichever way it
   says, stating the choice in the test's comment). Mutation-verify
   each guard red.

## Non-goals

No record writes (the sibling owns those). No backfill. The --force
escape stays narrow: verdict only, never the claim-collision
refusal (a collision is never repair). Verdict lines, refusal
grammar elsewhere, flow data untouched (_work/flowstats_test.tl).

---

(Original spec-authorship evidence:)

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
