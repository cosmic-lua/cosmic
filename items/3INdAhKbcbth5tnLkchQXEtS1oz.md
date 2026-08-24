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

Hit while implementing 3IKSjS8N, whose own Acceptance required
`bin/cosmic --make clean && --make fetch && --make build` (the
bootstrap check). Running the item's acceptance destroyed the worktree
the session needed to hand the item over, mid-slice. Recovery is
`git worktree prune && git worktree add o/board board` plus a rebuild
of `o/bin/gitboard` (~4s), so the cost is small but it is paid by
every session whose slice touches `clean`, and the failure arrives as
a confusing `cd: no such directory` rather than as anything naming the
cause.

Two shapes of fix, unranked here: move the documented worktree path
out of `o/` (it is not a build artifact, and nothing about it wants to
be one), or have `clean` refuse to delete a registered git worktree
under `o/`. The first is a skill/README edit; the second is a `_make`
change that protects any worktree, not just this one.
