## Goal

`pr.yml`'s `ci` lane must let a git subprocess spawned by the non-root
`builder` user (during the fenced `--make ci` step) read the repo's
local git config without hitting a permission error — so any test that
shells out to `git` against the checked-out repo (as
`_build/doc_paths_test.tl`'s `board_paths()` now does, in CI-fails-loud
mode) works reliably instead of failing on an unrelated credential-file
permission gap.

## Evidence

PR cosmic-lua/cosmic#1669 (board item `3Ip8waWfIBALaOYqycHmZosIITG`,
handle «mZos_IITG») turned `_build/doc_paths_test.tl`'s board-check from
a silent skip into a hard CI failure when `origin/board` "is not
readable here". Its `ci` job fails deterministically — confirmed via
`rerun_failed_jobs` on run 33825032384, job re-ran as job
100876964972, IDENTICAL failure on a fresh credentials-file UUID:

```
o/_build/doc_paths_test.lua:280: origin/board board paths unchecked in CI: origin/board is not readable here (warning: unable to access '/__w/_temp/git-credentials-9e05aeb0-f6e0-44e8-9180-903d875f45e9.config': Permission denied
fatal: bad config line 12 in file .git/config) — pr.yml's fetch step should have brought origin/board down
```

The message is misleading about WHERE it fails: the "fetch with network
allowed" step (`runuser -u builder -- git fetch -q --depth=1 origin
+refs/heads/board:refs/remotes/origin/board`) already succeeds —
`origin/board` genuinely IS present locally by the time the gate runs.
The failure is a SEPARATE git invocation, `board_paths()`'s own
`git ls-tree -r --name-only origin/board -- _work` (via
`cosmic.child.start`, `_build/doc_paths_test.tl:200-213`), spawned later
from inside the fenced `--make ci` step, still as `builder`.

Root cause: `actions/checkout` adds `includeIf.gitdir:...` entries to
the repo's LOCAL `.git/config` pointing at a credentials config file
under `/__w/_temp/` or `/github/runner_temp/` (see the job's own "Post
job cleanup" section, which unsets exactly these entries at job end).
That file is created by the runner's default (root) identity. `pr.yml`'s
"prepare non-root builder" step (`.github/workflows/pr.yml`) does
`chown -R builder:builder "$GITHUB_WORKSPACE" "$HOME"` — neither of
which covers `/__w/_temp/git-credentials-*.config` or
`/github/runner_temp/git-credentials-*.config`, so `builder` cannot
read them. ANY git command git invokes as `builder` against this repo
parses `.git/config`, hits the unreadable includeIf target, and fails
with `fatal: bad config line N in file .git/config` — not specific to
`board_paths()` or to this diff's shape. The two prior invocations that
worked (`prepare non-root builder`'s own `git config --system --add
safe.directory ...`, and the "fetch with network allowed" step's `git
fetch`) apparently tolerate or don't trigger the same parse path;
`git ls-tree` does. (Full reproduction: any `git` subcommand run as
`builder` inside the `ci` job's later steps is suspect, not just this
one call — worth confirming with a minimal repro before trusting the
scope below.)

This is pre-existing CI fragility, not something #1669 introduced: before
its diff, this exact permission failure hit the SAME code path
(`board_paths()` returning `nil, why`) but the caller only printed
`"skipped: ..."` and returned — invisible in a passing test's stdout
(only shown on a FAILURE report). #1669's diff is exactly what makes a
skip-worthy condition fail loud under CI, which is correct BY DESIGN
per that item's own goal — it just exposes that the environmental
premise ("pr.yml's fetch step brings origin/board down, so it should
always be readable") was incomplete: fetched and READABLE BY A GIT
SUBPROCESS AS BUILDER are two different things.

## Change

In `.github/workflows/pr.yml`'s `ci` job, "prepare non-root builder"
step: after the existing `chown` line, either (a) also chown the
credential config file(s) named by the repo's `includeIf.gitdir` entries
to `builder` (resolve the paths via `git config --local --get-regexp
'^includeIf\.gitdir:'`, before dropping to `builder`, since root can
still read them at that point), or (b) strip those `includeIf.gitdir`
entries from the local config entirely before the fenced step runs
(`git config --local --remove-section` per matched gitdir, mirroring
what the job's own "Post job cleanup" already does at the END — doing
it EARLY instead removes the dependency rather than working around it).
(b) is likely simpler and avoids trusting `builder` with credential
material it has no legitimate use for. Confirm the fix by re-running
`_build/doc_paths_test.tl` (or a smaller repro: any `git` subcommand run
as `builder` inside the fenced step) and observing it can now read
`.git/config` without the permission/parse error. Applies to the `build`
and `repro` jobs' identical "prepare non-root builder" step too, if they
ever run a test that shells out to `git` post-drop — confirm whether
they currently do before deciding whether to patch all three call sites
or just `ci`'s.

## Non-goals

Not `_build/doc_paths_test.tl` itself — its CI-fails-loud logic is
correct and unrelated to this bug; once this is fixed, #1669 should go
green with no changes on its side. Not a broader audit of what else a
non-root `builder` process can or can't read in this container — scoped
to the one credential-file permission gap this evidence identifies.
