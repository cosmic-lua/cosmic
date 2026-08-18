Imported from whilp/cosmic#1203.

## Goal

G8 — the flow system, via epic #1117. The board's WIP limits are committed
policy, and the method that tunes them by measurement is not written down
anywhere. This slice writes that section, describing a method against the
tooling the tree actually has today: reading the `board` branch's own git
history by hand.

## Change

Adopt PR #1171. Its 51 lines are a method written against `skills/plan/SKILL.md`
and the four-phase board (`shaping`/`ready`/`doing`/`review`); both are gone, and
the board's own git history — not a reporting verb — is the tooling the method
now reads. Land the corrected text.

The measured state of `skills/work/review.md`, this item's target root
(a fresh clone of `whilp/cosmic`, not the `board` worktree — the facts
below are the only ones `check`/`move ready` can verify against a single
root):

```facts
$ wc -l < skills/work/review.md
162
$ grep -ci "flow review" skills/work/review.md
0
$ grep -c "board.tl stats" skills/work/review.md
0
$ grep -cE "_plan/|plan:\*|shaping|column" skills/work/review.md
0
$ test -d skills/plan && echo yes || echo no
no
```

Reference only — verified by hand against the `board` worktree
(`git worktree add o/board board`) at refinement time, 2026-08-18; a
second, board-rooted `check` run cannot be automated today (the tool
takes one `--root`), so treat these as citations to confirm by eye
against `_work/flow.tl` and `items/*.tl`'s own git history before
writing the section, not as machine-checked facts:

```
$ sed -n '/^local LIMITS/,/^}/p' _work/flow.tl
local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  ["do"] = 5,
  check = 10,
  land = 3,
}
$ sed -n '/^local function admits_over_limit/,/^end/p' _work/flow.tl
local function admits_over_limit(from: string, to: string): boolean
  return to == "land" or is_return(from, to)
end
$ grep -c "counts_against_limit\|PhaseFlow" _work/flow.tl _work/gitverbs.tl _work/gitverdict.tl
_work/flow.tl:0
_work/gitverbs.tl:0
_work/gitverdict.tl:0
$ git log --format='%s' -- items/*.tl | awk '{print $1}' | sort | uniq -c | sort -rn
     21 move
     15 done
     13 new
      6 verdict
      2 unblock
      2 attach
$ git log --format='%ad %h %s' --date=iso-strict -- items/*.tl | grep -m3 -E ' (verdict|move) '
2026-08-18T03:41:17+00:00 970b2fe1 move 3I06cBmI ready -> do
2026-08-18T03:39:46+00:00 c65e7182 verdict 3HyCSe5U accept (check -> land)
2026-08-18T00:43:33+00:00 90f28e40 verdict 3HyCSe5U request changes (check -> do)
```

### `skills/work/review.md`

Insert ONE new section, `## tuning the limits: the flow review`, between
`## landings invalidate the queue` and `## the feedback half — never skip it`, so
the convergence paragraph stays the chapter's last word. Its content is PR
#1171's section with these ten corrections applied:

1. **vocabulary**: every "column" becomes "phase" (7 occurrences). The board has
   five named phases; nothing in this repo is called a column.
2. **the data source**: the record is the `board` branch's own git history over
   `items/*.tl` — every mutation is exactly one commit, pushed as it happens, so
   `git log` over that path is the complete, current record with nothing
   separate to fall behind it. Drop the label-event framing entirely
   (`labeled`/`unlabeled`, the `work:` label, legacy `plan:` spellings): PR
   #1171 read GitHub label timelines because the board was label-based when it
   was written. The board is committed files now, and the phase a move targets
   is text in a commit subject, not a label name.
3. **name the instrument**: the section must name the actual method —
   `git log --format='%ad %h %s' --date=iso-strict -- items/*.tl`, read by
   hand. A commit subject's first word is its verb (`new`, `attach`, `move`,
   `verdict`, `done`, `block`/`unblock`); a `move` or `verdict` subject also
   names the item's 8-character id prefix and its `<from> -> <to>` phase pair.
   Pairing successive lines for one id gives that item's stints: a stint
   starts at a `new`/`attach` commit that sets phase to `plan`, or at a
   `move`/`verdict` commit's target, and ends at the next commit naming that
   id. From the paired timestamps a planner counts stints per phase by hand,
   computes each stint's dwell (end minus start), and walks the ordered log
   tracking a running per-phase set of open ids to get peak concurrent
   occupancy; the same walk gives accept/rework/bounce counts and the
   `ready -> do` pickup latency (time between the two moves). A `move` subject
   carrying a trailing `(forced: ...)` is a repair, not organic flow, and is
   excluded. State plainly that this is a hand method — grep and arithmetic
   over timestamps — not a report a tool prints: PR #1171's text told the
   planner to "measure, per column" and named no tool because the verb it
   expected did not exist when it was written, and none is being built to
   replace it now either — the board's history is a day old, too thin yet for
   an instrumented report to say more than a direct read already does.
4. **drop p75; keep median and max, and say why by hand**: the board's history
   is one day old at review time, and a phase with a dozen stints has too few
   points for a percentile to mean anything a human can't get more honestly
   from just reading the sorted list. State median (the middle value once the
   stints' dwell minutes are sorted by hand) and max, and point at the paired
   `move`/`verdict` lines themselves as the citation, not a formula.
5. **mark the one unmeasurable metric**: keep the "refusals and their cost"
   bullet, and say that a refused move never becomes a commit — the verb
   prints its `REFUSED:` verdict line to the terminal and makes no mutation —
   so `git log` has nothing to show for it. That item comes from the session's
   own log, not from the log on disk.
6. **drop the occupancy caveat; nothing needs exempting**: an item that gains a
   child is de-phased in the SAME commit as the `attach` that gives it one, so
   a container never carries a phase and never appears as a `move` target —
   there is no epic sitting in `plan` for a hand count to subtract, unlike the
   label-era board PR #1171 was written against. A stint list read from
   `move`/`verdict` lines already counts only workable leaves; state this
   plainly instead of describing a subtraction step.
7. **rewrite the backward-moves bullet**: three log shapes carry backward
   motion, and a hand read must not conflate them. A bounce is a plain
   `move <id> <phase> -> plan` line with no `verdict` prefix — an implementer
   returning work it found under-specified, or a planner catching a `ready`
   item that should not have passed the bar — and it sends work back for
   re-specification. A rework is `verdict <id> "request changes" (check -> do)`
   — a targeted send-back naming concrete gaps, the rework signal.
   `verdict <id> reject (check -> plan)` is a third, harsher bounce: the
   approach itself was wrong. None of these is
   `verdict <id> accept (check -> land)`, which moves right, not back — a hand
   count that greps for `verdict` lines and calls anything backward must
   exclude accept explicitly, or it inflates the bounce rate with decisions
   that were never bounces.
8. **restate decision rule 1, on the real function**: `_work/flow.tl`'s
   `admits_over_limit(from, to)` is two lines — `to == "land" or
   is_return(from, to)` — a full phase admits only a return or an accept,
   everything else queues. Because containers never hold a phase (point 6), a
   raw occupancy count read from the log is already a count of genuine work in
   progress; decision rule 1 is not "exempt the things that aren't work" —
   there is nothing left to exempt — it is: when a hand count shows a phase
   over its `LIMITS` value, check whether the arrivals that pushed it there
   were returns or accepts, which the limit already lets through, before
   treating the number as a real signal that the limit itself is wrong.
9. **keep rules 2, 3 and 4 as written**, and point rule 2's "record a tripwire
   instead" at the actual location: the module doc comment at the top of
   `_work/flow.tl`, which today carries one line ("WIP limits carry the label
   board's empirically tuned values") and no evidence log yet — a flow
   review's tripwire is the first line that comment gains, not an addition to
   a list that already exists.
10. **correct the closing paragraph**: the path is `_work/flow.tl`, not
    `_plan/model.tl`, and its doc comment does not yet carry a review's
    empirical basis or any tripwires — a flow review's findings are the FIRST
    evidence appended there, establishing that block rather than extending one
    that already exists. Also drop the trigger phrase "refuses
    returns-adjacent work": returns are never refused, so the trigger is a
    refusal of ordinary intake or an ordinary pull, twice in one session.

### `skills/work/SKILL.md`

Two one-line edits, no new section:

- the chapter list's `review.md` entry ("the planner's review verdicts and the
  friction feedback loop") gains the flow review, so the method is discoverable
  from the chapter map.
- the sentence closing the WIP-limits paragraph — "retuning one is a reviewed
  change to the machinery, not a reading of this table" — gains a pointer to
  `review.md`'s flow review, so a reader who finds the limits finds the method.

### PR #1171 mechanics

- revert the branch's `skills/plan/SKILL.md` hunk; that path does not exist.
- rebase `claude/board-planning-review-mzdg5f` onto main.
- add `Closes #1203` to the PR body — without it `land` refuses the PR at its
  first gate.
- mark the PR READY for review. It is a draft today, and `land` cannot un-draft
  a PR.

## Non-goals

- **No change to `_work/flow.tl`'s limit numbers.** `plan = 12`, `ready = 12`,
  `do = 5`, `check = 10`, `land = 3` all stay exactly as they are. This slice
  writes the method that would tune them and tunes nothing.
- **No new tooling.** This slice is prose describing a manual git-log method;
  no new verb, module, or report is added, and `_work/flow.tl` is not edited.
  p75 dwell, a refusal counter, and an epic-filtered occupancy are not built
  either — the method says plainly which of these a hand read cannot do.
- No new evidence appended to `_work/flow.tl`'s doc comment: running a fresh
  flow review is not in this slice.
- No new or reorganized sections in `decompose.md`, `enable.md`, or
  `parallel.md`, and no change to `review.md`'s existing four sections.
- No history in the prose (`docs-style`): the section states the rules as they
  are, with no reference to commits, PRs, issue numbers, or the phase names the
  board used before.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/snippets_test.tl` ends `test: PASS` — `skills/`
  is in that test's read set, so any fence the new section adds must either
  compile at full strictness or not claim to be Teal.
- `grep -qi "## tuning the limits: the flow review" skills/work/review.md && echo present`
  prints `present` (the section is absent today: the facts block measures 0).
- `grep -qE "board\.tl stats|_work/(stats|model)\.tl|PhaseFlow" skills/work/review.md
  && echo present` prints nothing — the section names no reporting verb and no
  module that does not exist; all four spellings measure 0 today.
- `grep -cE "_plan/|plan:\*|shaping|column" skills/work/review.md` prints `0` —
  it prints 0 today, and the corrected section must not reintroduce any of the
  four stale spellings. Mind the substring: write "sends work back for
  re-specification", never "reshaping", which contains `shaping` and would fail
  this check on a word that is not a stale phase name.
- PR #1171 is not a draft, and its body contains `Closes #1203`.

## Enablement

none needed — the section describes a manual method (reading `git log` by
hand); it needs no new verb, module, or report, and `_work/flow.tl`'s `LIMITS`
table and `admits_over_limit` function already carry everything the method
reads. This slice is prose only, and its conventions are in AGENTS.md and the
`docs-style` skill.


---
_Generated by [Claude Code](https://claude.ai/code)_