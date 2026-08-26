`_build/casts_baseline.tl` and `_build/public_surface_baseline.tl` carry
`merge=union` in `.gitattributes`, whose comment there claims the strategy
"takes both sides' lines and yields the correct union with no duplicate
keys; a real collision, where both branches changed the SAME key, still
surfaces". Both halves of that claim are false in a case that actually
occurred.

Observed 2026-08-26 merging `origin/main` at `1b5163ea` (PR #1389) into
branch `3IQCjFxo` (PR #1391), a clean merge by git's own reckoning
(`git merge --no-commit --no-ff origin/main` exits 0, no conflict
markers, and GitHub reported the PR mergeable). The merged floor:

```
44:  ["cosmic/fetch/init.tl"] = 7,
45:  ["cosmic/fetch/verbs_test.tl"] = 1,
46:  ["cosmic/format/init.tl"] = 5,
47:  ["cosmic/format/init.tl"] = 9,
```

Two distinct defects in four lines:

1. **A duplicate key.** #1391 changed `cosmic/format/init.tl` from 9 to
   5; main still had 9. Union kept both. This one is LOUD — the build
   stops with `_build/casts_baseline.tl:47:3: error: redeclared key
   cosmic/format/init.tl (previously declared at
   _build/casts_baseline.tl:46:3)`. So "a real collision still surfaces"
   holds, but as a build error rather than a merge conflict, and only
   because `_tool.floor` refuses duplicates.

2. **A resurrected deletion, silently.** #1389 REMOVED the
   `cosmic/fetch/verbs_test.tl` row (that file dropped to zero casts, so
   it leaves the floor entirely). Union cannot express a deletion, so
   #1391's side put the row back. Nothing in the merge says so. Had
   defect 1 not stopped the build first, `_build/casts_test.tl` would
   have failed with `cosmic/fetch/verbs_test.tl: no casts left (baseline
   1)` — a confusing failure on a file the branch never touched.

The trigger is alphabetical adjacency: `cosmic/fetch/verbs_test.tl` and
`cosmic/format/init.tl` are consecutive rows, so one branch's deletion
and the other's value change land in one overlapping hunk, which is
exactly where the union driver applies. Disjoint regions merge normally
— PR #1390, deleting `cosmic/json_test.tl` and `cosmic/literal_test.tl`
against the same main, merged and regenerated with no diff at all. So
this is not rare-in-principle; it fires whenever two in-flight branches
touch neighbouring keys, which under a cast-closing epic is common.

The recovery is mechanical and known — `git checkout origin/main --
_build/casts_baseline.tl` then `bin/cosmic --make run _build/casts.tl
--baseline`, because a full regen is the only thing that computes both a
deletion and a changed value correctly. What is missing is that nothing
tells you to do it: the merge is clean, the PR reads mergeable, and the
first sign is a build error naming a line nobody wrote.

Worth deciding: whether `merge=union` is right for a floor whose rows are
DELETED as well as lowered (`.cosmic-coverage` differs — it has an
`on_duplicate` resolver and its rows are only ever lowered, never
removed, which is what makes union safe there); whether `_tool.floor`'s
duplicate refusal should name the regen command in its message the way
the stale-baseline check does; and, at minimum, whether the
`.gitattributes` comment should stop claiming a correctness it does not
have.

One consequence sharpens why the recovery has to start with `git
checkout origin/main -- <floor>`: the duplicate-key refusal is a
COMPILE error on a file in the build graph, so the tree will not build
far enough to reach the regen command the gate itself prints
(`bin/cosmic --make run _build/casts.tl --baseline`). Reaching for that
command first leaves the session hand-editing the duplicate row away,
which every spec under the casts epic lists as a Non-goal. Whatever the
fix is, the refusal's message should not point at a command its own
failure prevents from running.
