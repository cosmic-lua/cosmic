The board branch's `README.md` and the `work` skill both bootstrap the
board worktree at `o/board` inside a cosmic checkout:

```
git worktree add o/board board
```

`o/` is that checkout's build output directory, and `cosmic --make
clean` removes it — `clean: PASS (o, kept the verified bootstrap)`. So
any slice whose `Change` tells the session to run `--make clean` in the
same checkout destroys the board worktree it is operating the board
with, mid-session.

Hit for real on 2026-08-25 while implementing 3IOXhlWb, whose step 9 is
`bin/cosmic --make clean` before the gate. The session noticed in
advance and moved the worktree to `/home/user/board` with `git worktree
move`; a session that did not notice would have lost `o/board` and
`o/board/o/bin/gitboard` and had to re-add and rebuild. Nothing is
corrupted when it happens — board mutations commit and push as they
occur, so the state is on the remote — but the recovery is a re-add
plus a cold `bin/cosmic --make build`, and the failure surfaces as
"gitboard: command not found" with no hint of the cause.

Two candidate fixes, not decided here:

- Document a location outside `o/` in the board README and the `work`
  skill's bootstrap, since nothing about the worktree wants to be
  under the build output.
- Have `--make clean` skip a path that is a registered git worktree,
  the way it already keeps the verified bootstrap.

The first is cheaper and needs no `_make` change; the second protects
checkouts that already followed the documented path.
