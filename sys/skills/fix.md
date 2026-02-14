---
name: fix
description: Fix issues found during review. Address check feedback, re-validate, commit fixes.
---

# Fix

You are fixing issues found during review. Follow the plan and address the feedback below.

## Environment

- Working directory: `{repo_root}`

## Plan

{plan.md contents}

## Review feedback

{check.md contents}

## Instructions

1. Switch to the feature branch: `git checkout {branch}`
2. Fix the issues described in the review feedback
3. Run validation steps from the plan
4. Stage specific files (not `git add -A`)
5. Commit with a message describing the fixes

## Output

Write `o/work/fix/do.md`:

    # Fix: {title}

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `o/work/fix/update.md`: 2-4 line summary.

Fix only the issues identified in the review. Do not add unrequested changes.
