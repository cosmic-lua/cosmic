---
name: ship
description: Take a change from implementation to a pull request in cosmic -- tested, adversarially reviewed by a separate agent, its TODOs listed -- optionally set to auto-merge. Use when asked to implement and ship a change, or a list of changes as a sequence of PRs.
argument-hint: "[automerge] <what to change>"
---

# Ship a change

When the skill's arguments start with `automerge`, or the user asked
for auto-merge, step 6 enables it; otherwise the PR is left for a person
to merge.

## 1. Plan

- Split the work into PRs that each stand alone and pass CI. Changes that
  would conflict go in one PR, or in PRs landed one after another, each
  started from main once the one before has merged.
- Do not stack branches. main squash-merges through the queue, and a
  stacked child carries its parent's own commits, which duplicate or
  conflict with the parent's squash (or land it first, leaving the
  parent nothing to merge).
- Work them in sequence, one through step 6 before the next.

## 2. Implement

- `git fetch origin`, then
  `git worktree add -b <branch> "$(git rev-parse --show-toplevel)/../wt-<name>" origin/main`.
  Run everything after from that worktree's root, by absolute path. Keep
  `<branch>` the PR's branch name throughout, so `git push -u origin
  <branch>` pushes this worktree's commits and not another ref.
- Follow AGENTS.md there: `bin/zig build boot`; the change with a test
  that fails without it; each `TODO:` written the moment it is due;
  `o/bin/cosmic fix <changed-paths>`; `timeout 30 o/bin/cosmic test`; and
  its extra checks for C, `ci/`, and the launcher or fixtures
  (`ci/run-local`).
- Commit.

## 3. Adversarial review

Start a separate agent (a fresh context, not this one), give it the
worktree's path and `git diff origin/main...HEAD`, and ask it to break
the change:

- a case the change gets wrong, a test that would pass without the fix,
  a rule in AGENTS.md broken, a gap with no `TODO:`;
- each claim checked against the code, not the diff's story;
- each finding marked BLOCKING or nit, with a file and line.

Fix every BLOCKING finding and each nit that is cheap and plainly right;
say in the PR description why any are left. Re-run step 2's checks, and
review again after a large fix.

## 4. Record TODOs

From the worktree root, run
`o/bin/cosmic todos $(git diff --name-only --diff-filter=d origin/main...HEAD)`.
The change's own TODOs are those with no commit yet or with a commit on
this branch. The ones it resolved are the removed lines in
`git diff origin/main...HEAD | grep '^-.*TODO:'`.

## 5. Open the PR

- If main has moved since the branch started, `git fetch origin`,
  `git merge origin/main`, re-run step 2's checks and step 4, and review
  again if the merge conflicted: CI on a branch cut from an old main can
  fail on what main has since fixed.
- `git push -u origin <branch>`.
- Open a PR against main, titled in the repo's `area: summary` style. Its
  description says what changed and why, how it was verified, what the
  review found and what was done about it, and lists each TODO added
  (`file:line`, what it waits on) and resolved, or "none" as step 4
  showed.

## 6. Merge

- Without `automerge`, stop here once CI is green: the PR waits for a
  person. A next PR that does not depend on it starts from main now;
  once only dependent ones remain, stop and report which PRs remain and
  what each waits on.
- With `automerge`, enable auto-merge. main takes changes only through
  the merge queue, which runs CI again on the queued merge commit; watch
  both the branch's run and the queue's.
- On a failure, find the cause, fix it in the worktree, re-run step 2's
  checks, and push. Never skip or disable a test to get green.
- Once it has merged, `git worktree remove <path>` and
  `git branch -D <branch>` (a squash merge leaves it looking unmerged).
