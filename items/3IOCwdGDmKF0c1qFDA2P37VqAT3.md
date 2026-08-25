`gitboard block` reported failure, made its commit anyway, and left it
unpushed — and `sync` then reported the checkout current while it was
one commit ahead of the remote. The board's compare-and-swap rests on
"a mutation never half-lands"; this one did.

Observed 2026-08-25 ~02:53 UTC from a scheduled session, board worktree
at `o/board`, `o/bin/gitboard` built from `52b00a6`. Another session was
mutating the board concurrently (`6ef8475f block 3IOCdvXF on
3IOCdooE`, `c2c34e38 block 3IOCdooE on 3IOCdHTM` landed in the same
window), so this is the push-race path.

```
$ o/bin/gitboard block 3IOCgtWA 3IOCgCWG --reason '...'
gitboard-block: publish did not converge after 3 attempts

$ o/bin/gitboard sync
gitboard-sync: state is current          <-- but it was not

$ git rev-parse HEAD origin/board
eceffa3a58248f49ae2b98b3638bbfd1fa79115e     HEAD
6ef8475f23cf8e2de72b54a91b9733734f4baed0     origin/board

$ git log --oneline origin/board..HEAD
eceffa3a block 3IOCgtWA on 3IOCgCWG      <-- the "failed" mutation

$ git merge-base --is-ancestor origin/board HEAD && echo yes
yes
```

The commit was a clean fast-forward append the whole time — the rebase
half of the compare-and-swap had already succeeded and only the push
had not. Recovering it took `git push origin HEAD:board`, outside the
tool.

Two distinct defects, and the second is the dangerous one:

1. **`block` did not drop its commit on a failed publish.** The
   documented contract (board `README.md`, and the `work` skill) is
   that a refused push "drops its own commit whole, so a mutation never
   half-lands". After three non-converging attempts this one kept the
   commit and returned a failure verdict, so the session was told the
   mutation did not happen while the local board said it had.

2. **`sync` reported "state is current" with local ahead of remote.**
   Its help says "rebase onto the remote's state", and a session that
   trusts the verdict line — which the skill instructs it to do — has
   no signal that an unpublished mutation is sitting in its checkout.
   Every subsequent read in that worktree sees state nobody else can
   see. A later mutation would have published it silently as a
   side effect, attributing it to whatever commit came next.

Impact beyond the one lost push: a session that believes `block`
failed will retry it. The retry lands a second identical edge commit,
or refuses because the edge now exists — either way the session is
reasoning from a board state the verdict line denied.

Worth checking whether the retry loop is shared by every mutation verb
(`_work/gitgate.tl` is the commit-and-publish path per the branch
README) or is local to `block`; if shared, every verb has both
defects and the three attempts are just where a race happened to land
this time.
