---
name: pr
description: Open a pull request, resolve merge conflicts, and watch CI checks until green.
---

# PR

Open a pull request for the current branch, resolve any merge conflicts,
and monitor CI checks until they pass.

## Prerequisites

- Changes are committed and pushed to a feature branch
- `gh` CLI is authenticated

## Instructions

1. **Identify the branch and target**

   ```bash
   git branch --show-current
   git log --oneline main..HEAD
   ```

   Confirm you are on a feature branch with commits ahead of main.

2. **Open the pull request**

   ```bash
   gh pr create --fill --base main
   ```

   If a PR already exists for this branch, skip creation:

   ```bash
   gh pr view --json number,url,state
   ```

3. **Check for merge conflicts**

   ```bash
   gh pr view --json mergeable,mergeStateStatus
   ```

   If there are conflicts:
   - Fetch and rebase onto main:
     ```bash
     git fetch origin main
     git rebase origin/main
     ```
   - Resolve conflicts in each file. Read the conflicted file, understand
     both sides, edit to produce the correct merge.
   - After resolving all conflicts:
     ```bash
     git add <resolved files>
     git rebase --continue
     git push --force-with-lease
     ```
   - Re-check mergeable status.

4. **Watch CI checks**

   Poll check status until all checks complete (max 10 attempts, 30s apart):

   ```bash
   gh pr checks --watch --fail-fast
   ```

   If `--watch` is not available, poll manually:

   ```bash
   gh pr checks
   ```

   Repeat until all checks show pass or fail.

5. **Handle check failures**

   If checks fail:
   - Read the failing check logs:
     ```bash
     gh pr checks --json name,state,conclusion
     gh run view <run-id> --log-failed
     ```
   - Diagnose the failure. If it's a code issue you can fix:
     - Make the fix, commit, and push
     - Return to step 4
   - If it's a flaky test or infrastructure issue, note it and move on.

6. **Report result**

## Output

Write `o/work/pr/pr.md`:

    # PR

    ## URL
    <PR url>

    ## Conflicts
    <resolved|none|unresolved>

    ## Checks
    <pass|fail|pending>

    ## Notes
    <issues encountered>

Write `o/work/pr/update.md`: 2-4 line summary.
