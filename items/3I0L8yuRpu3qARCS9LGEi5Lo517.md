Imported from whilp/cosmic#1203.

## Goal

G8 — the flow system, via epic #1117. The board&#39;s WIP limits are committed
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

The measured state of the three files this touches:

```facts
$ wc -l &lt; skills/work/review.md
166
$ grep -ci &#34;flow review&#34; skills/work/review.md
0
$ grep -c &#34;board.tl stats&#34; skills/work/review.md
0
$ grep -cE &#34;_plan/|plan:\*|shaping|column&#34; skills/work/review.md
0
$ grep -c &#34;flow-review section&#34; _work/stats.tl
1
$ test -d skills/plan &amp;&amp; echo yes || echo no
no
$ sed -n &#39;/^local LIMITS/,/^}/p&#39; _work/model.tl
local LIMITS: {string: integer} = {
  plan = 12,
  ready = 12,
  [&#34;do&#34;] = 5,
  check = 10,
  land = 3,
}
$ sed -n &#39;/^local record PhaseFlow/,/^end/p&#39; _work/stats.tl
local record PhaseFlow
  phase: string
  stint_count: integer
  median_dwell_min: number
  max_dwell_min: number
  peak_occupancy: integer
  at_limit_min: number
end
$ grep -c &#34;p75&#34; _work/stats.tl
0
$ grep -c &#34;counts_against_limit&#34; _work/stats.tl
0
```

### `skills/work/review.md`

Insert ONE new section, `## tuning the limits: the flow review`, between
`## landings invalidate the queue` and `## the feedback half — never skip it`, so
the convergence paragraph stays the chapter&#39;s last word. Its content is PR
#1171&#39;s section with these ten corrections applied:

1. **vocabulary**: every &#34;column&#34; becomes &#34;phase&#34; (7 occurrences). The board has
   five named phases; nothing in this repo is called a column.
2. **the data source**: the record is every `labeled`/`unlabeled` event carrying a
   `work:` label. State that the replay also reads the historical
   `plan:` spellings (`model.LEGACY_PHASE`), because renaming a label on
   GitHub does not rewrite the name in an event that already happened.
3. **name the instrument**: the section must name
   `bin/cosmic --make run _work/board.tl stats --days N` and what it prints —
   per phase: stint count, median and max dwell minutes, peak occupancy, minutes
   at or over the limit; then the accept/rework/bounce counts and the `ready→do`
   pickup latency. PR #1171&#39;s text tells the planner to &#34;measure, per column&#34;
   and names no tool, because the verb did not exist when it was written.
4. **cut p75**: `stats` reports median and max dwell only. Drop p75 from the
   dwell bullet, or state plainly that p75 is a hand computation off the raw
   stints.
5. **mark the one unmeasurable metric**: keep the &#34;refusals and their cost&#34;
   bullet, and say that no label timeline records a refusal — a refused move
   leaves no event — so that item comes from the session&#39;s own log, not from
   `stats`.
6. **the occupancy caveat**: `stats` counts every stint in a phase and does not
   apply `counts_against_limit`, so its `peak` and `min at-limit` for `plan`
   include epics, while the live board&#39;s own count excludes them. A `plan`
   number is compared to the limit only after the epics are subtracted.
7. **rewrite the backward-moves bullet**: three kinds, not two — a bounce
   (`*→plan`) sends work back for re-specification, a rework (`check→do`) is a request-changes send-back
   and is the rework signal, an accept (`check→land`) is a verdict moving work
   on. PR #1171 calls `check→do` &#34;the accept path working&#34;; that described a
   board with no `land` phase and is now inverted.
8. **restate decision rule 1**: the epic exemption is not a proposal to
   consider. `model.counts_against_limit` already exempts an epic sitting in
   `plan`, and `model.admits_over_limit` is the single rule for an arrival at a
   full phase. The rule becomes: before moving a number, ask whether the phase is
   full of things that are not work in progress, and exempt them from the count
   the way `plan` already does.
9. **keep rules 2, 3 and 4 as written**, and point rule 2&#39;s &#34;record a tripwire
   instead&#34; at the tripwire lines that already sit in `_work/model.tl`&#39;s `LIMITS`
   comment.
10. **correct the closing paragraph**: the path is `_work/model.tl`, not
    `_plan/model.tl`, and the comment block beside `LIMITS` already carries a
    review&#39;s empirical basis and tripwires — so a flow review APPENDS its
    evidence to that block, it does not create it. Also drop the trigger phrase
    &#34;refuses returns-adjacent work&#34;: returns are never refused, so the trigger is
    a refusal of ordinary intake or an ordinary pull, twice in one session.

### `skills/work/SKILL.md`

Two one-line edits, no new section:

- the chapter list&#39;s `review.md` entry (&#34;the planner&#39;s review verdicts and the
  friction feedback loop&#34;) gains the flow review, so the method is discoverable
  from the chapter map.
- the sentence closing the board section — &#34;limits are policy, committed in
  `_work/model.tl`, tuned only by a reviewed change&#34; — gains a pointer to
  `review.md`&#39;s flow review, so a reader who finds the limits finds the method.

### PR #1171 mechanics

- revert the branch&#39;s `skills/plan/SKILL.md` hunk; that path does not exist.
- rebase `claude/board-planning-review-mzdg5f` onto main.
- add `Closes #1203` to the PR body — without it `land` refuses the PR at its
  first gate.
- mark the PR READY for review. It is a draft today, and `land` cannot un-draft
  a PR.

## Non-goals

- **No change to `_work/model.tl`&#39;s limit numbers.** `plan = 12`, `ready = 12`,
  `do = 5`, `check = 10`, `land = 3` all stay exactly as they are. This slice
  writes the method that would tune them and tunes nothing.
- **No new metrics in `stats`.** p75 dwell, a refusal counter, and an
  epic-filtered occupancy are three separate issues. `_work/stats.tl` is not
  edited at all, its doc comment included — the section is written at the path
  that comment already names, so no code moves.
- No new evidence appended to `_work/model.tl`&#39;s `LIMITS` comment: running a
  fresh flow review is not in this slice.
- No new or reorganized sections in `decompose.md`, `enable.md`, or
  `parallel.md`, and no change to `review.md`&#39;s existing four sections.
- No history in the prose (`docs-style`): the section states the rules as they
  are, with no reference to commits, PRs, issue numbers, or the phase names the
  board used before.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/snippets_test.tl` ends `test: PASS` — `skills/`
  is in that test&#39;s read set, so any fence the new section adds must either
  compile at full strictness or not claim to be Teal.
- `grep -qi &#34;## tuning the limits: the flow review&#34; skills/work/review.md &amp;&amp; echo present`
  prints `present` (the section is absent today: the facts block measures 0).
- `grep -q &#34;board.tl stats&#34; skills/work/review.md &amp;&amp; echo present` prints
  `present` (0 today).
- `grep -cE &#34;_plan/|plan:\*|shaping|column&#34; skills/work/review.md` prints `0` —
  it prints 0 today, and the corrected section must not reintroduce any of the
  four stale spellings. Mind the substring: write &#34;sends work back for
  re-specification&#34;, never &#34;reshaping&#34;, which contains `shaping` and would fail
  this check on a word that is not a stale phase name.
- PR #1171 is not a draft, and its body contains `Closes #1203`.

## Enablement

none needed — every mechanism the section describes already exists in the tree
(`_work/stats.tl`&#39;s report, `model.counts_against_limit`,
`model.admits_over_limit`, the `LIMITS` comment block). This slice is prose over
shipped tooling, and its conventions are in AGENTS.md and the `docs-style` skill.


---
_Generated by [Claude Code](https://claude.ai/code)_