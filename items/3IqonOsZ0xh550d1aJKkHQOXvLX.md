## Evidence

Found by the fresh-context review of PR #1688. That PR mirrored two
`pr.yml` steps into `release.yml` — the `includeIf.gitdir` credential
strip in "prepare non-root builder" and the `origin/board` fetch ahead
of `--make fetch` — because without them `_build/doc_paths_test.tl`'s
board check fails the release gate under `CI`. The drift was invisible
to every gate: `release.yml` had lacked both since #1669/#1674 landed
in `pr.yml` alone, and only a scheduled release run surfaced it, days
later, with no PR to attribute it to.

```
$ grep -n 'origin/board\|includeIf' _build/workflows_test.tl
(no output)
$ grep -n 'make ci' .github/workflows/*.yml
.github/workflows/pr.yml:…        o/bin/cosmic --make ci
.github/workflows/release.yml:…   o/bin/cosmic --make ci
```

`_build/workflows_test.tl` already ratchets, per job, the container
digest, `--privileged`, `useradd … builder` and `runuser -u builder`
(`jobs_in`, `containerised_jobs`, the tests at `:263-343`). It has no
rule for what a job that runs the gate as `builder` must do BEFORE
dropping: the two lines above are exactly that class. Deleting
`release.yml`'s new fetch line today passes every gate and breaks the
next release. Re-measure the greps at pickup; line numbers move.

## Change

One test added to `_build/workflows_test.tl` (443 lines; stays under
500):

`test_every_gate_lane_strips_includeif_and_fetches_the_board_ref`:
for every job whose body contains `--make ci` (derive with
`job_body`, over `workflows()`), assert the same job body contains
(a) `git config --local --remove-section "includeIf.gitdir:` — the
strip loop — and (b) `+refs/heads/board:refs/remotes/origin/board` —
the board fetch. Message names the workflow, the job, and which of
the two is missing, and says why: `_build/doc_paths_test.tl` fails
rather than skips under `CI` when `origin/board` is unreadable
(`doc_paths_test.tl:268-282`). Today the set is `pr.yml:ci` and
`release.yml:build`; the test derives it, never lists it, so a third
gate lane inherits the rule.

Mutation: delete `release.yml`'s fetch line → the test fails naming
`release.yml` `build` and the fetch; restore.

Wall: no workflow file changes; `doc_paths_test.tl` unchanged.
Gate: `bin/cosmic --make ci` ends `ci: PASS`.

## Non-goals

Not extending the rule to `perf.yml`/`fuzz.yml`/`docs.yml`: none runs
`--make ci`, and `doc_paths_test.tl` runs only under the gate.
