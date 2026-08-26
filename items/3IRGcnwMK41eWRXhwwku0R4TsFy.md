`_build/casts_baseline.tl` is merged with git's `union` strategy, and
`.gitattributes` states the property that buys: "takes both sides'
lines and yields the correct union with no duplicate keys; a real
collision, where both branches changed the SAME key, still surfaces".
Landing three sibling PRs off the same base on 2026-08-26 showed the
comment overstates it in two ways, and both cost a landing session real
work.

**A duplicate key does get produced.** #1391 changed
`["cosmic/format/init.tl"] = 9` to `= 5`; main had the row unchanged.
Merging main into that branch produced BOTH lines, adjacent:

```
46:  ["cosmic/format/init.tl"] = 5,
47:  ["cosmic/format/init.tl"] = 9,
```

`_tool.floor`'s refusal did fire, which is the good half — but it
fires as a COMPILE error on a file in the build graph:

```
_build/casts_baseline.tl:47:3: error: redeclared key cosmic/format/init.tl
  (previously declared at _build/casts_baseline.tl:46:3)
```

so the regen command the gate prints (`bin/cosmic --make run
_build/casts.tl --baseline`) cannot run either — the tree will not
build far enough to reach it. The session must hand-edit the duplicate
away first, which is exactly what every spec under the casts epic
lists as a Non-goal, and only then can it run the regen. The recovery
the landing rule describes is one command; here it is a hand edit
followed by that command.

**A deletion is silently reverted.** #1389 dropped
`["cosmic/fetch/verbs_test.tl"] = 1` from the floor. Merging that main
into #1391's branch brought the row BACK, with no conflict and no
duplicate key, because union takes both sides' lines and one side
still had it. Nothing refuses this: the floor stays valid, it compiles,
and the ratchet reads a stale allowance for a file that now has zero
casts. It surfaces only as `_build/casts_test.tl`'s "no casts left
(baseline %d)" if that check is reached, and is invisible to a session
that trusts the clean merge. Under this epic — where the dominant edit
IS a row deletion — that is the common case, not the corner one.

The countermeasure is not obvious and is worth refining: possibilities
include dropping `merge=union` for the two floors so a real conflict
stops the merge, teaching the floor reader to resolve duplicates the
safe direction the way `.cosmic-coverage` already does with its
`on_duplicate` resolver (the lower value, never the higher), or making
the regen runnable against a tree that does not compile. What is
certain is the current state: `.gitattributes` documents a guarantee
the strategy does not provide, so at minimum that comment is wrong.

Evidence: PRs #1389, #1390, #1391, landed 2026-08-26; the duplicate
was observed merging `origin/main` at `1b5163ea` into #1391's head
`72994221`, the revived row merging `b9e53b45` into the same branch.

## Triaged: duplicate

`3IRFM0t3` (filed eleven minutes earlier, placed under G4) is the same
two defects from the same merge, and states them more completely: it
covers `_build/public_surface_baseline.tl` as well, names the trigger
(alphabetical adjacency putting a deletion and a value change in one
overlapping hunk), gives the negative control (#1390, disjoint rows,
merged clean), and gives a recovery that needs no hand edit — `git
checkout origin/main -- <floor>` then the regen. The one thing this
item said that it did not — that the duplicate-key refusal is a compile
error, so the regen command the gate prints cannot run — has been folded
into its spec. Nothing here is lost; work the finding under `3IRFM0t3`.
