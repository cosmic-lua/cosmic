# contributing

how a change gets from an idea to main. [`AGENTS.md`] holds the build
and test loop; this doc holds the pull request around it.

## split the work

each PR stands alone and passes CI. changes that would conflict go in
one PR, or in PRs landed one after another, each started from main once
the one before has merged.

do not stack branches. main squash-merges through the merge queue, so a
stacked child carries its parent's own commits, which duplicate or
conflict with the parent's squash.

## start a branch

1. look for the API first. `bin/cosmic docs <words>` searches every doc
   comment and example by what it does (`cosmic docs find program path`
   answers [`Proc.find`]). open PRs may carry it too.
2. cut one branch per PR, named for the change, fresh from
   `origin/main`. never reuse a branch whose PR has merged or closed.
3. give it a worktree of its own:

   ```text
   git fetch origin
   git worktree add -b <branch> ../wt-<name> origin/main
   ```

   work from that worktree's root by absolute path, and keep `<branch>`
   the PR's branch name so `git push -u origin <branch>` pushes this
   worktree's commits.
4. `bin/zig build boot` there.

## check before pushing

- the change has a test that fails without it ([`doc/testing.md`]).
- `bin/cosmic fix <changed-paths>`, then `timeout 30 bin/cosmic test`.
- `bin/cosmic fix --check .` when the change touches what the whole-tree
  checks read.
- a change under `.github/`: `bin/cosmic test build/workflows_test.tl`.
- a change to C, `ci/`, the launcher, startup, the artifact format or a
  fixture: [`ci/run-local`] (`ci/run-local fixtures` to re-run edited
  fixtures), and the C checklist in [`AGENTS.md`].
- a change to a harness module can alter what a pass or fail means:
  see "changing the harness" in [`doc/testing.md`].
- a documentation-only edit needs no rebuild or test run, but still
  `bin/cosmic fix` on the doc. comments follow [`doc/writing.md`].

## review

a second person or agent reviews the diff before it merges: a fresh
reader with the worktree path and `git diff origin/main...HEAD`, asked
to break the change. they look for a case it gets wrong, a test that
would pass without the fix, a rule of [`AGENTS.md`] broken, a gap with
no `TODO:`, and a comment that is wrong. every claim is checked against
the code, not the diff's story. each finding is marked BLOCKING or nit,
with a file and line.

fix every BLOCKING finding and each nit that is cheap and plainly
right. say in the PR description why any are left. re-run the checks, and
review again after a large fix.

## TODOs

the policy is in [`AGENTS.md`]. at the end, from the worktree root:

```text
bin/cosmic todos $(git diff --name-only --diff-filter=d origin/main...HEAD)
```

the change's own TODOs are those with no commit yet or with a commit
listed by `git log origin/main..HEAD`. the ones it resolved are the
removed lines in `git diff origin/main...HEAD | grep '^-.*TODO:'`.

## open the PR

- if main has moved, `git fetch origin` and `git merge origin/main`,
  re-run the checks, and review again if the merge conflicted. CI on a
  branch cut from an old main can fail on what main has since fixed.
- `git push -u origin <branch>`.
- title it `area: summary`.
- the description says what changed and why, how it was verified, what
  review found and what was done about it, and lists each TODO added
  (`file:line`, what it waits on) and each resolved, or "none".

## merge

main takes changes only through the merge queue, which runs CI again
on the queued merge commit ([`.github/workflows/ci.yml`] runs on
`merge_group`). enable auto-merge, and watch both the branch's run and
the queue's. start a next PR that depends on this one only once it has
merged.

on a failure, find the cause, fix it in the worktree, re-run the checks
and push. never skip or disable a test to get green.

once it has merged, clean up:

```text
git worktree remove <path>
git branch -D <branch>
```

a squash merge leaves the branch looking unmerged, so `-D`. delete the
worktree's build directory too ([`build/paths.tl`] names it).

## moving the driver pin

[`bin/zig`], [`bin/vendor`], `ci/` and the standalone scripts run on the
release [`ci/cosmic-driver.pin`] names, not on the tree. what a change
adds reaches them only once the pin moves, and it can only move after
the change merges and main publishes its `next-<commit>` prerelease
([`ci/README.md`]).

when a change adds what a `TODO:` waiting on the pin needs, or API those
scripts would use, open a follow-up once that prerelease exists. move
the pin to it (its commit, URL and SHA-256, checked against the digest
the release records) and take up every `TODO:` the release unblocks:
`bin/cosmic todos '"cosmic-driver.pin"'` lists them. otherwise say in
the PR that the pin was left alone.

[`.github/workflows/ci.yml`]: ../.github/workflows/ci.yml
[`AGENTS.md`]: ../AGENTS.md
[`bin/vendor`]: ../bin/vendor
[`bin/zig`]: ../bin/zig
[`build/paths.tl`]: ../build/paths.tl
[`ci/cosmic-driver.pin`]: ../ci/cosmic-driver.pin
[`ci/README.md`]: ../ci/README.md
[`ci/run-local`]: ../ci/run-local
[`doc/testing.md`]: testing.md
[`doc/writing.md`]: writing.md
[`Proc.find`]: ../cosmic/proc.tl
