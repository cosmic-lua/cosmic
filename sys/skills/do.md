---
name: do
description: Execute a work plan. Create branch, make changes, run validation, commit.
---

# Do

You are executing a work item. Follow the plan below.

## Environment

- Working directory: `{repo_root}`

## Plan

{plan.md contents}

## Instructions

1. Read every file you intend to modify before editing it
2. Create the feature branch: `git checkout -b {branch} origin/main`
3. For each step in the plan:
   a. Make the changes for that step
   b. Before staging, run `git status` and verify only your files are affected
   c. Stage the specific files changed (not `git add -A`)
   d. Commit with a descriptive message for that step
4. Run validation steps from the plan
5. If validation requires fixes, stage and commit them

## Forbidden

Do not use destructive git commands: `git reset --hard`, `git checkout .`,
`git clean -fd`, `git stash`, `git commit --no-verify`.

## Output

Write `o/work/do/do.md`:

    # Do: {title}

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `o/work/do/update.md`: 2-4 line summary.

Follow the plan. Do not add unrequested changes.
