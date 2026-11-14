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
4. `bin/zig build boot` there: the host's core, taken from a release
   where the tree's C is that release's ([`AGENTS.md`]), and the tree, which is
   all the loop below runs ([`AGENTS.md`] says what that host-only tool
   leaves to `bin/zig build boot -Dboot-cores=all`). zig's caches and the Teal compile cache
   (`COSMIC_BUILD_CACHE` names another file, `0` none) are shared by
   every checkout, so a fresh worktree compiles little. only
   the tree's own tool rebuilds or boots: another cosmic (a release) run
   in a stale tree refuses and exits 3. a tool built from another path
   (a worktree's copied build directory, a moved checkout) refuses the
   checkout: run `bin/zig build boot` there.

   on an x86_64 box the build runs the checked core and the host's
   shipped core, which are built for x86-64-v3, so the box's CPU needs
   AVX2, FMA, BMI1 and BMI2, F16C, LZCNT and MOVBE.

   on an aarch64 Linux box the same holds for the Armv8.2-A core: the
   CPU needs dot-product and half-precision floats (Cortex-A55 or
   Neoverse N1 and newer, a Raspberry Pi 5; not a Raspberry Pi 4).

## check before pushing

- the change has a test that fails without it ([`doc/testing.md`]).
- `bin/cosmic fix <changed-paths>`, then `bin/cosmic test` on the tests of
  what changed, then the full suite, `timeout 2700 bin/cosmic test`
  ([`doc/testing.md`] says how long it takes).
- `bin/cosmic fix --check .` when the change touches what the whole-tree
  checks read. it takes 5 to 11 minutes (`timeout 2400`) where no
  checkout of the host has checked the tree's files with the same
  checking code, and about 3 where one has: what a check found of a file
  is kept by the file's content, and the checkouts whose `cosmic fix`
  is the same bytecode on the same core share it
  ([`build/check_memo.tl`]). it says which of its checks it is on.
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
- a change to a harness module needs nothing recorded: every key holds
  the harness's code. see "changing the harness" in [`doc/testing.md`]
  for the `epoch` bump a change outside its code may need.
- a documentation-only edit needs no test run, but still
  `bin/cosmic fix` on the doc. comments follow [`doc/writing.md`].

## markers only fall

the checker still finds things in the tree that a rewrite has not
removed yet. each is held where it occurs, by a marker: a trailing
comment on the line the finding is reported at, naming the stage and the
codes, as in `local x = t[k] -- checked: map_field`. the stages are
`scoped`, `declared`, `checked` and `untyped` (`-- untyped: call`, a call
the checker gave no function); a line may hold several, in the one
comment (`-- declared: float_key -- checked: map_field, nil_not_allowed`),
and `code*2` holds two findings of a code on a line. a line that ends
inside a long string cannot take a comment, so its marker is a comment
of its own on the line above, which begins `-- checked:` and holds the
line below it. [`build/markers.tl`] has the rules.

- a finding with no marker for its code on its line is refused, by a
  compile of the module and by the tree check: fix the code. a marker is
  never the fix, and none is ever added.
- a new rule of the checker that finds existing code lands with that code
  fixed. a marker written by hand for it (`-- <stage>: <code>`) is
  refused against the merge base, which held none of its code, and no
  file of counts exists to take a row.
- a marker whose finding is gone is stale. `bin/cosmic fix .` removes
  it, and `fix --check` and the tree check name it. run `fix .` after
  a change that removes findings and commit what it wrote.
- the markers only fall. the tree check `ceilings`
  ([`build/ceilings_base.tl`]) counts each file's markers of each code and
  refuses a file that holds more than it did at the merge base with
  main, so a marker cannot be added, and one that is written over a
  line that moved is not new. it reads the base with git alone (`git
  grep` and `git cat-file`), with no run of the checker. CI runs it in
  the merge queue (and on main's runs), against the merge base with
  main and never the entry ahead in the queue, where it fails when no base
  can be found (the step that finds it says why: run the job again), and
  `bin/cosmic fix --check .` runs it locally against `git merge-base HEAD
  origin/main`, saying so when there is no `origin/main` (`git fetch
  origin main`) or no git checkout. a file renamed with markers loses
  them: the key is the path.
- code that moves keeps its markers, since they are on its lines. a
  change that moves a finding to another line moves its marker, and a
  marker left behind is stale where the finding is no longer.

a code none of whose findings remain is closed by that alone: no list
names it. a marker for a code no file held a marker of at the merge base
is refused by the ratchet, which says the rule has no exceptions and to
fix the code, so taking a code's last marker closes it, and a new rule of
the checker starts closed.

The examples a reader copies (`*_example.tl`) hold their findings by
markers too: a marker is part of the text `cosmic docs` shows, and
`cosmic fix --check .` refuses a finding with none and a marker whose
finding is gone. A code block of a guide holds none, since a reader copies
the block: a finding there is fixed, and so is one in a file under
`ci/testdata`.

## teal layout

`bin/cosmic fix <paths>` lays out every Teal file it is given
([`build.fix.format`]), and `fix --check` fails on a file that is not
laid out or that the formatter refuses (a syntax error, a layout that
is not the same file, or one that is not a fixed point). run `fix` on
the files you changed and commit what it wrote. the rules, which the
formatter holds and a reviewer need not:

- spacing follows the syntax. one space around binary operators and
  after a comma, none before; `:` has none before and one after. unary
  operators hug their operand, except `not`. calls and indexes close up.
  tables are `{ a = 1, 2 }`, empty `{}`. an attribute follows its name:
  `local x <const>`. strings, numbers and types keep their bytes.
- indentation is 2 columns per block. `end`, `else`, `elseif` and
  `until` line up with their opener.
- a continuation line indents from the innermost open bracket: 2 more
  than the line that opened it, 4 in an `if` or loop header or a
  function signature. a closing bracket that starts a line sits level
  with the line that opened it. outside brackets a statement continues
  2 in.
- one statement per line. a block stays on one line only if each body
  holds at most one statement, that statement is not a block, an `if`
  has at most two branches, and the whole ends by column 100. otherwise
  it opens fully. the formatter adds no other break and removes none;
  it does not wrap a long line.
- a line that starts with a binary operator moves the operator to the
  end of the line before.
- a table has a trailing comma if and only if it closes on its own line.
- blank lines collapse to one. there is no trailing whitespace, and the
  file ends with exactly one newline.
- a comment on a line of code is one space after it. a comment on its
  own line takes the indent of the code after it, or keeps its column
  shifted with its statement.

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

main takes changes only through the merge queue, which runs CI on the
queued merge commit ([`.github/workflows/ci.yml`] runs on
`merge_group`). a push to a branch runs no CI: the checks above, run
locally, are the branch's. a pull request runs one light check, the `ci`
check the queue requires of it: the tree booted and `fix --check` of
what it changed, with the checks spanning files over the whole tree.
enable auto-merge, and watch the queue's run.
start a next PR that depends on this one only once it has merged.

on a failure, find the cause, fix it in the worktree, re-run the checks
and push. never skip or disable a test to get green.

the queue's run is a light, fast gate: linux-x86_64's native suite and
the format check of what the change touched. everything else (the other legs, assemble, the
regressions and product suite, the checked suite and the checked
narrowing run) runs on main's push after the merge, and macOS in main's
daily scheduled run, so a failure only those show turns main red after
the change lands; fix it, or revert the change, at once. a change to what they prove more than the native suite
does (ci/, bin/, the core's C, `build.zig`, vendor/ and patch/, the
harness's epoch, the artifact, launcher and boot modules, a darwin
branch or anything macOS-specific, code the checked core or a checked run would catch) runs CI on
its branch first: a manual run (`workflow_dispatch` on the branch, from
the Actions tab or `gh workflow run ci.yml --ref <branch>`) runs what
main's run does.

a queue run tests the change merged with every entry ahead of it, so it
can fail where the branch's checks passed. when it fails building, on a
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
the change merges and main publishes its `<YYYYMMDD>-<commit>` prerelease
([`ci/README.md`]).

[`bin/zig`], [`bin/vendor`] and [`bin/verify-codesign`] each run their
Teal ([`build/zig.tl`], ...) through [`bin/cosmic-bootstrap`], which
fetches that release once and caches it by digest. [`bin/cosmic`] asks
[`build/paths.tl`] for the build directory the same way.
`COSMIC_BOOTSTRAP=<path>` makes [`bin/cosmic-bootstrap`] answer another
cosmic instead, such as the tree's own tool (by its path in the build
directory, which `bin/cosmic build` prints; [`bin/cosmic`] itself is
refused), for all of them and for CI's driver step alike.

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

the pin is also the seed a boot compiles the tool's compiler from: a
`build.zig` step runs the release's `cosmic compile` over the
files of [`build/seed.txt`] ([`build/seed.tl`] and what it requires), and the
bridge ([`core/bridge.lua`]) loads the Lua it writes as the boot's first
stage. The first stage compiles the same files again from the tree (the
second stage, the tree's own generator applied to the tree's own source), and
the second stage compiles everything up to [`build.boot`]. The seed's source
may use only what that release parses; a boot whose seed refuses it fails
naming the file and line, and the pin must move to a release that parses it.
a change to what the generator in [`lang/codegen.tl`] writes also differs from
the seed, which the bridge refuses unless the change adds `lang/SEED_DIFFERS`
naming, one a line, each seed source whose Lua differs ([`lang/codegen.tl`], ...):
source paths, no comments. a difference in a file not listed still fails the
boot, as does a listed file that does not differ; the pin move that takes a
release carrying the change empties the list and removes the file.
`COSMIC_BOOTSTRAP` names another cosmic for the seed too. a seed that is not
the pinned release is not held to a listed file that does not differ: the
tree's own tool as the seed compiles every file as the second stage does, so
a standing entry would always fail, and the pinned boot (unset
`COSMIC_BOOTSTRAP`, as CI boots) still refuses it, which removes the entry at
the pin move. a difference not listed fails the boot under any seed, since
the tool named can be older than the tree's generator.

[`.github/workflows/ci.yml`]: ../.github/workflows/ci.yml
[`AGENTS.md`]: ../AGENTS.md
[`bin/cosmic-bootstrap`]: ../bin/cosmic-bootstrap
[`bin/cosmic`]: ../bin/cosmic
[`bin/vendor`]: ../bin/vendor
[`bin/verify-codesign`]: ../bin/verify-codesign
[`bin/zig`]: ../bin/zig
[`build.boot`]: ../build/boot.tl
[`build.fix.format`]: ../build/fix/format.tl
[`build/ceilings_base.tl`]: ../build/ceilings_base.tl
[`build/check_memo.tl`]: ../build/check_memo.tl
[`build/markers.tl`]: ../build/markers.tl
[`build/paths.tl`]: ../build/paths.tl
[`build/seed.tl`]: ../build/seed.tl
[`build/seed.txt`]: ../build/seed.txt
[`build/zig.tl`]: ../build/zig.tl
[`ci/cosmic-driver.pin`]: ../ci/cosmic-driver.pin
[`ci/README.md`]: ../ci/README.md
[`ci/run-local`]: ../ci/run-local
[`core/bridge.lua`]: ../core/bridge.lua
[`doc/c.md`]: c.md
[`doc/testing.md`]: testing.md
[`doc/writing.md`]: writing.md
[`lang/codegen.tl`]: ../lang/codegen.tl
[`Proc.find`]: ../cosmic/proc.tl
