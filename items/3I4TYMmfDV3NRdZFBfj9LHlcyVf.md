Found while auditing the ready bar's execution surface (2026-08-18 session,
no PR).

## What happens

`_work/facts.tl:99` runs every `$` line of a spec's ` ```facts ` block as
shell, in the product checkout:

```text
local result, err = child.run({"/bin/sh", "-c", f.command}, {cwd = root})
```

No allowlist, no sandbox, exit status ignored. `gitgate.fact_problems`
(`_work/gitgate.tl:142`) calls it from `ready_problems`, so `check ID` and
`move ID ready` both execute whatever text the sidecar carries.

This is not a security vulnerability today, and the finding does not claim
it is: the only writer of `items/**` is someone with push access, who can
already run code through a `*_test.tl` or a `*_gen.tl`; no external text
reaches the parser (`gh.pull`'s body feeds `review.blocks_check` only, never
`facts.parse`); and `board.yml` runs `--make ci`, never `check`. The finding
is that the machinery is not paying for itself, and that the property
keeping it safe is provenance rather than confinement — one feature away
from being untrue.

## What it costs

```text
$ wc -l _work/facts.tl _work/facts_test.tl
139 _work/facts.tl
87 _work/facts_test.tl
```

Plus `gitgate.fact_problems` and its module-record entry, the `root?`
parameter threaded through `ready_problems` -> `cmd_check` -> `cmd_move`,
`gitboard.root_flag()` on two verbs (`_work/gitboard.tl:58,85,102,229,240`),
`store.main_worktree` (`_work/store.tl:418`, whose only caller is
`fact_problems`), two tests (`_work/gitverbs_test.tl:297-328`), and a
bespoke failure mode for a board that is not a worktree of a product
checkout.

## What it has caught

Two. `git log --format=%s origin/board | grep -c -- '-> ready'` is 2 —
`3I06cBmI` and `3HyEEgwb`, both carrying a facts block, both passing. Every
other item on the board entered in the wholesale issue import (d1cdc9fe),
which never ran the bar. So the executor has run in anger twice and caught
nothing yet. Small sample, stated as such.

## What it is producing instead

16 of 59 sidecars carry a facts block. Several are HTML-entity mangled by
the import path finding 3I4832Yh describes, e.g. in
`items/3I0L8yuRpu3qARCS9LGEi5Lo517.md` and
`items/3HyCSe5UymQuLd6ZuQr16pklSp9.md`:

```text
$ wc -l &lt; skills/work/review.md
$ test -d _perf/peers &amp;&amp; echo exists || echo absent
```

Under `/bin/sh` the first reads a file named `&lt;` and the second backgrounds
on the bare `&`. Neither can pass. Both items sit past the point where the
bar would have run them, because the import bypassed it — so today these are
latent false failures waiting for the first re-check, not observed ones.

The same entity bug has already forced the board twice on the adjacent
Acceptance-quoting gate (item 3HyCSe5U, commits fe6e8704 and 2c43e5c5, both
`--force --why`). That is the pattern the executor is on course to repeat.

## Why the shape is wrong, not just the sample size

A fact failure is ambiguous at the moment it fires. It means the tree moved
under a stale spec (the signal), or the command was mistyped or mangled
(noise), or `--root` resolved to the wrong tree (noise). Two of the three
are noise, and all three exit through the same `--force`. A gate whose
common outcome is an override teaches the board to override.

Every command in every facts block on the board today is `wc -l`, `grep -c`,
`ls`, or `test -d` — pure measurement. Nothing in the corpus needs a shell
beyond a `<` redirect.

## Change shape (to be settled in refinement)

Delete the executor; keep the discipline. A ` ```facts ` block becomes inert
evidence — the command the planner ran at refinement time and the output it
produced — read by the implementer, re-measured by the planner at
re-refinement, never re-run by a verb. `decompose.md`'s "measured, not
inferred" rule survives intact; what goes is "`check` and `move ID ready`
RUN the block" and "write them to be run", plus `review.md:144-146`'s
staleness framing, where the countermeasure for a wrong tree-fact becomes a
re-measure. Staleness detection lands where the loop already handles it: the
bounce -> countermeasure step.

Refinement settles: whether the fence keeps the name `facts` (16 sidecars
and the skill's vocabulary use it) or is renamed to something that reads as
inert; and whether `store.main_worktree` goes with it or has a second caller
by then.

If the staleness catch later proves load-bearing — visible as a rising
bounce rate citing wrong premises — the rebuild is a closed vocabulary
evaluated in-process (`lines <path>`, `matches <pattern> <path>`,
`exists <path>`) over `cosmic.fs`, not `/bin/sh` again. That is smaller than
what is there now and cannot be mangled into a background job.

## Relation to the board's other facts items

- 3I28cCZV ("check must refuse an Acceptance that asserts a count with no
  facts block behind it") explicitly assumes "no change to how facts are
  EXECUTED (that half works)". This finding disputes that premise. The two
  are compatible in outcome: 3I28cCZV's gate is a pure text check over the
  body — a counting Acceptance must have a facts block — and it does not
  need the executor. Removing the executor makes 3I28cCZV purely textual.
  Whichever lands first, the other's spec needs a line about the split.
- 3I4832Yh (HTML entities from the issue import) is the separate, real bug
  that this finding's mangled blocks are a symptom of. Fixing it makes the
  facts blocks readable again but does not change the cost or the catch
  rate.

## Non-goals

Not a claim of a vulnerability, and not a request to sandbox the executor —
confinement would add machinery to a feature whose problem is that it has
too much. No change to the ready bar's five required sections. No sweep of
existing sidecars beyond whatever the fence rename, if any, requires.
