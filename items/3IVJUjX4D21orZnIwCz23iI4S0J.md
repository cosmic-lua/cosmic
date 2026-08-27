## Goal

G8 — the flow system (parent 3HyRdT1J). "No session accepts its own
work" holds at the verdict verb itself, across a rework takeover: the
original builder reaching for `verdict` directly is refused on a diff
they built, exactly as `next` already withholds it from them.

## Change

One source file and one test file, on the `board` branch.

**1. `_work/gitverdict.tl` (249 lines) — the refusal reads the durable
record.** Line 145's own-build refusal compares `session == (it.claim
or "")` — the claim alone. Replace the predicate with
`flow.built_by(it, session)` (`_work/flow.tl`: claim now, or in
`builders` ever), adding the `_work.flow` require. The refusal message
becomes `REFUSED: %s is %s's own build — the claim or builders record
names them, and no session accepts its own work`. Update the preceding
doc comment (lines 139-144), which still says "the claim … is what is
checked": the durable half exists now, and this is the verb reading it.

**2. `_work/gitverdict_test.tl` (205 lines) —
`test_verdict_refuses_a_past_builder`.** An item in `check` whose
`claim` names a second builder and whose `builders` carries the first:
a verdict by the first builder is refused (exit 1, no verdict written),
a verdict by the second is refused, and a verdict by a third session
lands. Build the state through the verbs where the file's existing
fixtures allow, or by `store.save` of an item carrying both fields —
the predicate under test is field-driven either way.

Measured 2026-08-27 at board head: `wc -l _work/gitverdict.tl` 249,
`_work/gitverdict_test.tl` 205; `grep -n "session == (it.claim"
_work/gitverdict.tl` → line 145 and nowhere else.

## Non-goals

- No change to `flow.built_by` itself: prefix awareness for
  orchestrator waves is 3IVJVZJt, mergeable independently (different
  files; this diff only calls the function).
- No change to `next`'s routing (`_work/action.tl` already consults
  `built_by`) or to the review-claim path (`gitreview`).
- No change to the unnamed-session stance: an empty `session` is still
  not refused — a repair written without one still works.

## Acceptance

- `bin/cosmic --make ci` from the board worktree ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverdict_test.tl` passes, including
  `test_verdict_refuses_a_past_builder`.
- `grep -c "session == (it.claim" _work/gitverdict.tl` is 0.
- Reverting the one-line predicate (back to claim equality) turns
  `test_verdict_refuses_a_past_builder` red.

## Enablement

none needed — one verb file and its test on this branch, gated by
`bin/cosmic --make ci` from the worktree; no blocker items.

## Evidence

Found 2026-08-27 reviewing the board machinery for concurrency gaps.

`_work/gitverdict.tl:145` refuses a self-accept with `session ==
(it.claim or "")` — the claim alone. The durable half exists and is
consulted everywhere else: `flow.built_by` (`_work/flow.tl`) answers
"claim now, or in `builders` ever", and `next`'s `reviewable` walk uses
it, precisely because a rework takeover moves the claim while the item's
diff stays the first builder's. So after `move ID check --claim <second>
--force --why ...`, `next` correctly withholds the item from the first
builder — but the first builder reaching for `verdict` directly is not
refused on its own diff, since `it.claim` now names the second session.
The skill says "honour it if you reach for `verdict` directly", which is
honor-system at exactly the spot a one-line tool rule (`flow.built_by(it,
session)` instead of the claim equality) would enforce it. Related but
distinct: 3ITAFU4F is the takeover ERASING the record before `builders`
existed; this is the verdict verb not READING the record that now exists.
