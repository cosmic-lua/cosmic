## Evidence

Measured 2026-09-04 from the Actions API. The `release.yml` run
dispatched at 04:21Z on `79aa8c16` (`33836481771`) fails in job `build`
at "the gate, under the binary being released", on a cause different
from the perf-gate failure «6JrA_3Dgs» records for the 09-03 run:

```
.coverage/_build/doc_paths_test.tl (exit 1):
  failing tests:
    test_every_board_reference_names_a_file_on_the_board_branch
    o/_build/doc_paths_test.lua:280: origin/board board paths unchecked in CI:
      origin/board is not readable here (warning: unable to access
      '/__w/_temp/git-credentials-….config': Permission denied
      fatal: bad config line 12 in file .git/config)
      — pr.yml's fetch step should have brought origin/board down
coverage: FAIL (1 of 278 files)
ci: FAIL (coverage)
```

Two changes made `pr.yml`'s `ci` job pass this same test, and both
touched `pr.yml` only: #1669 («mZos_IITG») made the board check FAIL
under `CI` instead of skipping, and #1674 («djEO_SQWp», `8d19e027`,
`git show --stat 8d19e027` → `.github/workflows/pr.yml | 17 +`)
strips the `includeIf.gitdir` credential includes before dropping to
`builder`. `release.yml` runs the identical gate (`o/bin/cosmic --make
ci`, `release.yml:117-118`) as the same non-root `builder` from the
same checkout action, and has neither:

```
$ grep -n 'includeIf\|origin/board\|refs/heads/board' .github/workflows/release.yml
(no output)
$ sed -n 184p .github/workflows/pr.yml
          runuser -u builder -- git fetch -q --depth=1 origin +refs/heads/board:refs/remotes/origin/board
```

So every release run since #1669 merged fails the gate before reaching
the perf compare, and no release can carry `8758f80c` (#1661) or
`96afd807` (#1650) until it is fixed — which is what «Xvox_XNCM», and
through it three cosmos pin bumps, wait on.

## Change

Two edits to `.github/workflows/release.yml`'s `build` job, each a
verbatim copy of the `pr.yml` lines it mirrors (keep them identical so
a future reader diffing the two lanes sees no drift):

1. In the "prepare non-root builder" step, after
   `git config --system --add safe.directory "$GITHUB_WORKSPACE"`
   (`release.yml:59`), append the includeIf strip block from
   `pr.yml:157-172` — the comment and the `git config --local
   --name-only --get-regexp '^includeIf\.gitdir:' | while … git config
   --local --remove-section "includeIf.gitdir:${gitdir}"; done` loop.
2. In the "build the release binaries" step's `bash -ec` script
   (`release.yml:87-91`), before `bin/cosmic --make fetch`, add
   `git fetch -q --depth=1 origin +refs/heads/board:refs/remotes/origin/board`
   (the `pr.yml:184` command; it already runs as `builder` inside
   that `runuser`), with `pr.yml:176-179`'s comment explaining why the
   board ref is fetched here.

Nothing else in the workflow moves; the perf gate failure «6JrA_3Dgs»
describes is a separate cause with its own item. Proof is the lane:
after merge, a `workflow_dispatch` of `release.yml` (prerelease, perf
gate on) gets past "the gate, under the binary being released" —
`doc_paths_test.tl` green in the run log — whether or not the perf
compare then passes.

## Non-goals

- Not the perf-gate regression (`re_match_log_line`) — «6JrA_3Dgs» /
  «c5wU_p1n9».
- No change to `pr.yml`, `_build/doc_paths_test.tl`, or the test's
  fail-under-CI rule; the release lane is brought up to the gate lane,
  not the other way around.
