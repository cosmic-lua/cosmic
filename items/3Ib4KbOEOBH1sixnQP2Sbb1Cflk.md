## Change

`gitboard next` carries the last bounce's gap when it offers a
recently-dropped item, so the next session starts from the recorded
gap instead of re-discovering it.

Reproduced 2026-08-29 on a scratch board (board head c5c3928):
`GITBOARD_SESSION=b1 gitboard drop ID --why "the encoding question is
unanswered"`, then

    GITBOARD_SESSION=b2 gitboard next
    gitboard-next: pull 3Ib4mK2b the slice — highest-priority todo item
    passing the spec bar with no open blocker

— the gap lives only in the board log ("drop 3Ib4mK2b: the encoding
question is unanswered" is the item's most recent commit), and the
offer says nothing. Observed twice in scenario evals: the next session
re-takes and re-discovers the identical gap.

The change, in `_work/gitview.tl` (227 lines now —
`wc -l < _work/gitview.tl`) and `_work/store.tl` only if it lacks the
read (check first: `store.history(s, id)` already returns events
newest-first with `subject` — reuse it, add nothing):

1. A pure helper in gitview: `bounce_note(subject: string): string` —
   given an item's most recent board-commit subject, returns
   `" (last bounce: <why>)"` when the subject matches
   `^drop %S+: (.+)$`, and `""` otherwise (a `drop %S+ review:`
   subject is a reviewer release, not a bounce — it returns "").
2. In `cmd_next`, when the decided action's kind is `pull`, read
   `store.history(s, action.item.id)` (first entry only) and append
   `bounce_note(subject)` to the action's reason before rendering.
   Alternates are left alone — one history read per ask, not one per
   candidate.
3. In `show ID` nothing changes — the history it already prints
   carries the drop line.

Tests: the pure `bounce_note` cases (a drop subject yields the note,
a reviewer-release drop and a take subject yield "") in
`_work/gitview_test.tl`; one store-backed case in
`_work/gitspec_test.tl`'s style — take, drop --why, then `cmd_next`
output contains "last bounce:" and the why text — using the
`_work.fixture` harness.

## Non-goals

The bar is untouched: a bounced item STAYS pullable (holding it off
pullable until the spec moves was considered and not chosen — the gap
may be answerable by the next session without a spec edit, and the
bound already throttles churn). Existing verdict-line formats
unchanged; the note is appended to `next`'s reason text, which is not
a frozen format.
