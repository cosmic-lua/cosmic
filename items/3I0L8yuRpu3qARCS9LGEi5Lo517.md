Imported from whilp/cosmic#1203.

## Refinement blocker (2026-08-18) — not resolved, do not move to ready

Re-checked against the CURRENT `board` worktree while attempting to drive
this item to the ready bar. Two separate problems found and only the first
is fixed here:

1. **Fixed.** The spec sidecar carried raw HTML entities (`&#39;`, `&#34;`,
   `&lt;`, `&amp;`) baked into its prose and its `facts` commands — same
   defect as finding 3I4832Yh, this time breaking `gitboard check`'s fact
   execution itself (a `$ wc -l &lt; file` fact runs literally through
   `/bin/sh -c` and does nothing like the intended redirect), not just the
   PR-quoting gate 3I4832Yh named. Decoded via `gitboard spec` in this
   pass; see 3I4832Yh, whose evidence this reinforces (now three
   occurrences — the countermeasure there should stop being optional).
2. **Not fixed — blocks ready.** `_work/stats.tl` and `_work/model.tl`, the
   two files this item's Change and Acceptance cite throughout (the
   `PhaseFlow` record, the `LIMITS` table, the `stats` CLI verb this
   section is supposed to document), **do not exist in the current board
   tree.** `LIMITS` now lives in `_work/flow.tl` (confirmed:
   `grep -n "^local LIMITS" _work/flow.tl` → line 35), but no `PhaseFlow`
   record, no dwell/stint/occupancy reporting, and no `stats` verb exist
   anywhere in `_work/**` today (confirmed:
   `grep -rln "PhaseFlow\|stint_count\|flow-review" _work/*.tl` → no
   matches). `git log --oneline -- _work/stats.tl _work/model.tl` shows
   both existed before the board's `d1cdc9fe` orphan-history reset
   ("board: the work system and its state, on their own history") and
   were not carried forward into it — the measurement tooling this item
   was written to document was dropped in that reset, not merely renamed.
   This item cannot be refined to the ready bar as scoped: there is
   nothing left to write a `## tuning the limits: the flow review`
   section ABOUT. Before this item can move again, a planner needs to
   decide whether the `stats`/flow-review measurement tool gets rebuilt
   under the new `_work/` layout (a different, larger item this one would
   then depend on) or whether the flow-review method is redesigned around
   whatever the current tree actually offers. Left in `plan`, unscoped,
   for that decision — do not re-attempt this refinement without first
   answering that question.

## Goal

G8 — the flow system, via epic #1117. The board's WIP limits are committed
policy, and the method that tunes them by measurement is not written down
anywhere: `_work/stats.tl` was built to feed that method and its own doc comment
points readers at a section of `skills/work/review.md` that does not exist. This
slice writes that section, correcting the text drafted on PR #1171 to describe
the tooling the tree has.

## Change

Adopt PR #1171. Its 51 lines are a method written against `skills/plan/SKILL.md`
and the four-phase board (`shaping`/`ready`/`doing`/`review`); both are gone, and
the tooling the method assumed to be proposed now exists. Land the corrected
text, at the path `_work/stats.tl` already names.

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
against `_work/stats.tl` and `_work/model.tl` before writing the
section, not as machine-checked facts:

```
$ grep -c "flow-review section" _work/stats.tl      # 1
$ sed -n '/^local LIMITS/,/^}/p' _work/model.tl
local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  ["do"] = 5,
  check = 10,
  land = 3,
}
$ sed -n '/^local record PhaseFlow/,/^end/p' _work/stats.tl
local record PhaseFlow
  phase: string
  stint_count: integer
  median_dwell_min: number
  max_dwell_min: number
  peak_occupancy: integer
  at_limit_min: number
end
$ grep -c "p75" _work/stats.tl                        # 0
$ grep -c "counts_against_limit" _work/stats.tl        # 0
```

### `skills/work/review.md`

Insert ONE new section, `## tuning the limits: the flow review`, between
`## landings invalidate the queue` and `## the feedback half — never skip it`, so
the convergence paragraph stays the chapter's last word. Its content is PR
#1171's section with these ten corrections applied:

1. **vocabulary**: every "column" becomes "phase" (7 occurrences). The board has
   five named phases; nothing in this repo is called a column.
2. **the data source**: the record is every `labeled`/`unlabeled` event carrying a
   `work:` label. State that the replay also reads the historical
   `plan:` spellings (`model.LEGACY_PHASE`), because renaming a label on
   GitHub does not rewrite the name in an event that already happened.
3. **name the instrument**: the section must name
   `bin/cosmic --make run _work/board.tl stats --days N` and what it prints —
   per phase: stint count, median and max dwell minutes, peak occupancy, minutes
   at or over the limit; then the accept/rework/bounce counts and the `ready→do`
   pickup latency. PR #1171's text tells the planner to "measure, per column"
   and names no tool, because the verb did not exist when it was written.
4. **cut p75**: `stats` reports median and max dwell only. Drop p75 from the
   dwell bullet, or state plainly that p75 is a hand computation off the raw
   stints.
5. **mark the one unmeasurable metric**: keep the "refusals and their cost"
   bullet, and say that no label timeline records a refusal — a refused move
   leaves no event — so that item comes from the session's own log, not from
   `stats`.
6. **the occupancy caveat**: `stats` counts every stint in a phase and does not
   apply `counts_against_limit`, so its `peak` and `min at-limit` for `plan`
   include epics, while the live board's own count excludes them. A `plan`
   number is compared to the limit only after the epics are subtracted.
7. **rewrite the backward-moves bullet**: three kinds, not two — a bounce
   (`*→plan`) sends work back for re-specification, a rework (`check→do`) is a request-changes send-back
   and is the rework signal, an accept (`check→land`) is a verdict moving work
   on. PR #1171 calls `check→do` "the accept path working"; that described a
   board with no `land` phase and is now inverted.
8. **restate decision rule 1**: the epic exemption is not a proposal to
   consider. `model.counts_against_limit` already exempts an epic sitting in
   `plan`, and `model.admits_over_limit` is the single rule for an arrival at a
   full phase. The rule becomes: before moving a number, ask whether the phase is
   full of things that are not work in progress, and exempt them from the count
   the way `plan` already does.
9. **keep rules 2, 3 and 4 as written**, and point rule 2's "record a tripwire
   instead" at the tripwire lines that already sit in `_work/model.tl`'s `LIMITS`
   comment.
10. **correct the closing paragraph**: the path is `_work/model.tl`, not
    `_plan/model.tl`, and the comment block beside `LIMITS` already carries a
    review's empirical basis and tripwires — so a flow review APPENDS its
    evidence to that block, it does not create it. Also drop the trigger phrase
    "refuses returns-adjacent work": returns are never refused, so the trigger is
    a refusal of ordinary intake or an ordinary pull, twice in one session.

### `skills/work/SKILL.md`

Two one-line edits, no new section:

- the chapter list's `review.md` entry ("the planner's review verdicts and the
  friction feedback loop") gains the flow review, so the method is discoverable
  from the chapter map.
- the sentence closing the board section — "limits are policy, committed in
  `_work/model.tl`, tuned only by a reviewed change" — gains a pointer to
  `review.md`'s flow review, so a reader who finds the limits finds the method.

### PR #1171 mechanics

- revert the branch's `skills/plan/SKILL.md` hunk; that path does not exist.
- rebase `claude/board-planning-review-mzdg5f` onto main.
- add `Closes #1203` to the PR body — without it `land` refuses the PR at its
  first gate.
- mark the PR READY for review. It is a draft today, and `land` cannot un-draft
  a PR.

## Non-goals

- **No change to `_work/model.tl`'s limit numbers.** `plan = 12`, `ready = 12`,
  `do = 5`, `check = 10`, `land = 3` all stay exactly as they are. This slice
  writes the method that would tune them and tunes nothing.
- **No new metrics in `stats`.** p75 dwell, a refusal counter, and an
  epic-filtered occupancy are three separate issues. `_work/stats.tl` is not
  edited at all, its doc comment included — the section is written at the path
  that comment already names, so no code moves.
- No new evidence appended to `_work/model.tl`'s `LIMITS` comment: running a
  fresh flow review is not in this slice.
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
- `grep -q "board.tl stats" skills/work/review.md && echo present` prints
  `present` (0 today).
- `grep -cE "_plan/|plan:\*|shaping|column" skills/work/review.md` prints `0` —
  it prints 0 today, and the corrected section must not reintroduce any of the
  four stale spellings. Mind the substring: write "sends work back for
  re-specification", never "reshaping", which contains `shaping` and would fail
  this check on a word that is not a stale phase name.
- PR #1171 is not a draft, and its body contains `Closes #1203`.

## Enablement

none needed — every mechanism the section describes already exists in the tree
(`_work/stats.tl`'s report, `model.counts_against_limit`,
`model.admits_over_limit`, the `LIMITS` comment block). This slice is prose over
shipped tooling, and its conventions are in AGENTS.md and the `docs-style` skill.


---
_Generated by [Claude Code](https://claude.ai/code)_