The `work` skill's bootstrap puts the board worktree at `o/board`
(`git worktree add o/board board`, SKILL.md "the board in one minute",
repeated in the `board` branch's own README). `o/` is the build
system's output directory, and `cosmic --make clean` removes it whole:

```
$ bin/cosmic --make clean
clean: PASS (o, kept the verified bootstrap)
$ cd o/board
/bin/bash: cd: o/board: No such file or directory
$ git worktree list
/home/user/cosmic          4a8fee8d [claude/...]
/home/user/cosmic/o/board  c422310f [board] prunable
```

**Hit twice, by two different slices whose own Acceptance required a
`clean`.**

- Implementing `3IKSjS8N`, whose Acceptance required
  `bin/cosmic --make clean && --make fetch && --make build` (the
  bootstrap check). Running the item's acceptance destroyed the
  worktree the session needed to hand the item over, mid-slice.
- **2026-08-25**, implementing `3IOXhlWb`, whose step 11 is
  `bin/cosmic --make clean` before the gate — the census slice had to
  delete its throwaway strict `tl` prototype, which lives in `o/`. That
  session noticed in advance and removed the worktree deliberately,
  re-adding and rebuilding after the gate. One that did not notice
  would have lost `o/board` and `o/board/o/bin/gitboard` and met
  "gitboard: command not found" with no hint of the cause.

The recurrence is structural, not bad luck: any slice that must prove
something about a cold tree has to run `clean`, and the board worktree
is documented into the exact directory `clean` exists to empty.

Recovery is `git worktree prune && git worktree add o/board board` plus
a rebuild of `o/bin/gitboard` (~4s), so the cost is small — nothing is
corrupted, because board mutations commit and push as they occur and
the state is on the remote. What it costs is a confusing failure
(`cd: no such directory`, or a missing binary) that names nothing about
its cause, paid by every session whose slice touches `clean`.

Two shapes of fix, unranked here: move the documented worktree path
out of `o/` (it is not a build artifact, and nothing about it wants to
be one), or have `clean` refuse to delete a registered git worktree
under `o/`. The first is a skill/README edit; the second is a `_make`
change that protects any worktree, not just this one.
