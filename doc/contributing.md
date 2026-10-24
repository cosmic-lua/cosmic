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
   `origin/main`. never reuse a branch whose PR has merged or closed, even one a
   session was started on or told to push to.
3. give it a worktree of its own:

   ```text
   git fetch origin
   git worktree add -b <branch> ../wt-<name> origin/main
   ```

   work from that worktree's root by absolute path, and keep `<branch>`
   the PR's branch name so `git push -u origin <branch>` pushes this
   worktree's commits.
4. `bin/zig build boot` there: the host's core and the tree, which is
   all the loop below runs ([`AGENTS.md`] says what that host-only tool
   leaves to `bin/zig build boot -Dboot-cores=all`). zig's caches and the Teal compile cache
   (`COSMIC_BUILD_CACHE` names another file, `0` none) are shared by
   every checkout, so a fresh worktree compiles little, and what it
   does compile it compiles in worker processes, one fewer than the
   processors (`COSMIC_BUILD_JOBS` names another count, `1` none). only
   the tree's own tool rebuilds or boots: another cosmic (a release) run
   in a stale tree refuses and exits 3.

## check before pushing

- the change has a test that fails without it ([`doc/testing.md`]).
- `bin/cosmic fix <changed-paths>`, then `bin/cosmic test` on the tests of
  what changed, then the full suite, `timeout 2700 bin/cosmic test`
  ([`doc/testing.md`] says how long it takes).
- `bin/cosmic fix --check .` when the change touches what the whole-tree
  checks read. it takes 5 to 11 minutes (`timeout 2400`), and says which
  of its checks it is on.
- a change under `.github/`: `bin/cosmic test build/workflows_test.tl`.
- a change to the artifact format, the launcher or `cosmic build`:
  `bin/zig build boot -Dboot-cores=all` first, so that the tool carries
  every core and the tests that need one (`all_cores`) run rather than
  skip, which a host-only tool reports.
- a change to C, `ci/`, the launcher, startup, the artifact format or a
  fixture: [`ci/run-local`] (`ci/run-local fixtures` to re-run edited
  fixtures), and for C the checklist in [`doc/c.md`]. a change to `ci/`
  also needs `../bin/cosmic fix --check` from `ci/`, a tree of its own
  with its own build directory. its `fixtures/*_test.tl` run only under
  the CI driver. run as root, [`ci/run-local`] runs the driver as an
  unprivileged user (`COSMIC_CI_LOCAL_USER`), as CI's runners are. the
  launcher fixture's core is a stand-in that checks nothing: a case about
  the real core belongs in `runtime_test.tl`.
- a change to a harness module can alter what a pass or fail means:
  see "changing the harness" in [`doc/testing.md`].
- a documentation-only edit needs no test run, but still
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

the policy is in [`doc/writing.md`]
([todo comments](writing.md#todo-comments)): leave each TODO the moment it
is due. when the work is done, list every `TODO:` it added, with
`file:line` and what it waits on, in the summary and the PR description.
take the list from this, from the worktree root, and do not write "none"
from memory:

```text
bin/cosmic todos $(git diff --name-only --diff-filter=d origin/main...HEAD)
```

the change's own TODOs are those with no commit yet or with a commit
listed by `git log origin/main..HEAD`. the ones it resolved are the
removed lines in `git diff origin/main...HEAD | grep '^-.*TODO:'`.

## open the PR

- if main has moved, `git fetch origin` and `git merge origin/main`,
  re-run the checks and the TODO listing, and review again if the
  merge conflicted. CI on a
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

a branch push whose change touches what only the queue's legs prove (ci/,
the build and core inputs, the harness's epoch, the artifact and launcher
modules: [`.github/scripts/branch-scope.txt`]) runs the queue's scope on the
branch, so those failures show there, and it takes about as long as the
queue's run does; any other branch push runs the light scope.

a queue run tests the change merged with every entry ahead of it, so it
can fail where the branch's run passed. when it fails building, on a
type error in code the change did not touch, it has met another change:
never queue the same head again. find the entry it met (the error names
its code); if that entry is still queued, wait for it to land or leave.
then bring main in as "open the PR" says, fix what the checks report,
push, and enable auto-merge again. a flake or a runner's loss is not
this: find its cause as above.

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

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] each run their
Teal ([`build/zig.tl`], ...) through [`bin/cosmic-bootstrap`], which
fetches that release once and caches it by digest. [`bin/cosmic`] asks
[`build/paths.tl`] for the build directory the same way.
`COSMIC_BOOTSTRAP=<path>` makes [`bin/cosmic-bootstrap`] answer another
cosmic instead, such as the tree's own tool (by its path in the build
directory; [`bin/cosmic`] itself is refused), for all of them and for CI's
driver step alike.

when a change adds what a `TODO:` waiting on the pin needs, or API those
scripts would use, open a follow-up once that prerelease exists. move
the pin to it with `cosmic release`, giving the commit main merged it as
(a later release carries it too; with no `--commit` it takes the
newest):

```text
bin/cosmic release --commit <commit> --pin ci/cosmic-driver.pin
```

it writes the pin's three lines (commit, URL and SHA-256) only once the
binary it downloads has the digest the release records. then take up
every `TODO:` the release unblocks, which
`bin/cosmic todos '"cosmic-driver.pin"'` lists. otherwise say in the PR
that the pin was left alone.

the pin is also the seed a boot compiles the checker from: a `build.zig`
step runs the release's `cosmic compile` over `checker/*.tl`, and the
boot's first stage is the Lua it writes. the checker's source may use only
what that release parses; a boot whose seed refuses it fails naming the
file and line, and the pin must move to a release that parses it. a change
to what the generator in [`checker/tl.tl`] writes also differs from the
seed, which the boot refuses unless the change adds `checker/SEED_DIFFERS`
naming, one a line, each seed output file whose Lua differs (`tl.lua`,
`flow.lua`, ...): bare output file names, no paths and no comments. a
difference in a file not listed still fails the boot, as does a listed
file that does not differ; the pin move that takes a release carrying
the change empties the list and removes the file.
the same holds for the new checker's own source, `lang/`, which the pinned release compiles (`compile --grammar new`) once the
switch makes it the seed of the tool. Until then CI's rehearsal job compiles the translation of all of `lang/` with the
tree's compile and with the pinned release, and holds the files whose Lua differs to `lang/SEED_DIFFERS`, one bare output
name a line (`codegen.lua`), both ways: a change to what the new checker's code generator writes that the pin lacks lists its files there, a
listed file that does not differ fails, and the pin move that takes a release carrying the change empties the list and
removes the file (`bin/cosmic build/lang_proof_main.tl prove <dir> --seed $(bin/cosmic-bootstrap)` runs it).
the seed the switch boots from is [`build/seed.txt`] (the files of the entry [`build/seed.tl`] and what it requires), compiled
by the pinned release, and the bridge that loads it is [`core/bridge_new.lua`]; neither boots anything yet.
`bin/cosmic build/seed_proof_main.tl prove <dir>` writes the translated tree, compiles the seed with the pinned release,
and boots the tree through that bridge up to [`build.boot`]; with `--tool` it boots a copy of the tree and leaves a tool to
test. for the bridge `lang/SEED_DIFFERS` names source paths ([`lang/codegen.tl`]); the proof of lang/ reads those too.
`COSMIC_BOOTSTRAP` names another cosmic for the seed too. with it pointing
at the tree's own tool, the seed is always what the checker compiles itself
to, so a standing entry fails the boot saying to remove it: boot with the
pinned release (unset `COSMIC_BOOTSTRAP`) or leave the file out locally,
and keep the entry in the commit.

[`.github/scripts/branch-scope.txt`]: ../.github/scripts/branch-scope.txt
[`.github/workflows/ci.yml`]: ../.github/workflows/ci.yml
[`AGENTS.md`]: ../AGENTS.md
[`bin/cosmic-bootstrap`]: ../bin/cosmic-bootstrap
[`bin/cosmic`]: ../bin/cosmic
[`bin/vendor`]: ../bin/vendor
[`bin/verify-codesign`]: ../bin/verify-codesign
[`bin/zig`]: ../bin/zig
[`build.boot`]: ../build/boot.tl
[`build/paths.tl`]: ../build/paths.tl
[`build/seed.tl`]: ../build/seed.tl
[`build/seed.txt`]: ../build/seed.txt
[`build/zig.tl`]: ../build/zig.tl
[`checker/tl.tl`]: ../checker/tl.tl
[`ci/cosmic-driver.pin`]: ../ci/cosmic-driver.pin
[`ci/README.md`]: ../ci/README.md
[`ci/run-local`]: ../ci/run-local
[`core/bridge_new.lua`]: ../core/bridge_new.lua
[`doc/c.md`]: c.md
[`doc/testing.md`]: testing.md
[`doc/writing.md`]: writing.md
[`lang/codegen.tl`]: ../lang/codegen.tl
[`Proc.find`]: ../cosmic/proc.tl
