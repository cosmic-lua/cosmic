---
name: triage-issues
description: Triage open GitHub issues. Assess priority, deduplicate, label, close stale issues, and refine underspecified issues.
---

# triage-issues

Triage open issues in the repo. Assess priority, deduplicate, apply labels,
and refine underspecified issues.

## Usage

```
/skill:triage-issues [--label <filter>] [--limit <n>]
```

## Steps

1. **Fetch open issues**
   ```bash
   gh issue list --state open --limit 50 --json number,title,body,labels,createdAt,updatedAt
   ```
   If `--label` was provided, add `--label <filter>` to the command.
   If `--limit` was provided, use that instead of 50.

2. **Read codebase context** to understand what's actionable:
   - `sys/system.md`
   - `sys/work/*.md` — work phases
   - `Makefile` — build/test targets
   - scan `lib/` and `bin/` for source files referenced in issues

3. **For each issue, assess:**
   - **actionability**: is the problem clear? can it be worked on now?
   - **priority**: p0 (critical/blocking), p1 (high/impactful), p2 (low/minor)
   - **duplicates**: does it overlap with another open issue?
   - **staleness**: is it outdated or already resolved by recent changes?
   - **labels**: which labels should be added or removed?
   - **specificity**: is the body detailed enough to act on? does it identify
     files, functions, root causes, and a concrete approach?

4. **Check for duplicates** by reading bodies of related issues:
   ```bash
   gh issue view <number> --json body,comments
   ```

5. **Apply triage decisions** — for each issue that needs changes:
   ```bash
   # add priority label
   gh issue edit <number> --add-label "p1"

   # close duplicate, referencing the canonical issue
   gh issue close <number> --comment "duplicate of #<canonical>"

   # close stale/resolved issues
   gh issue close <number> --comment "resolved — <reason>"

   # flag issues needing more context
   gh issue edit <number> --add-label "needs-investigation"
   ```

6. **Refine one underspecified issue** — pick the thinnest issue (shortest
   body, fewest details) that is still open and actionable. Research the
   codebase to fill in specifics, then update it:

   - read the source files referenced or implied by the issue
   - identify the current state: what exists, what code paths are involved,
     exact file paths and line numbers
   - write a concrete proposed approach with files to modify
   - add constraints, edge cases, and relationships to other issues
   - update the issue body:
     ```bash
     gh issue edit <number> --body "<refined body>"
     ```
   - add appropriate labels if missing

   Do only one issue per triage run. Prefer issues that are labeled `todo`
   (the work loop will pick them up) but have bodies too vague to act on.

## Priority criteria

- **p0**: blocks the work workflow, causes data loss, or breaks core functionality
- **p1**: significant friction affecting most runs, clear fix path
- **p2**: minor annoyance, cosmetic, or rare edge case
- enhancements get no priority label unless urgent

## Output

Print a triage summary table:

```
## Triage summary

| # | title | action | reason |
|---|-------|--------|--------|
| 97 | friction: remove per-phase friction.md | keep p0 | blocks workflow improvement |
| 140 | friction: sandbox blocks bash | close duplicate | same root cause as #135 |
| 55 | support session name aliases | refine | body lacks file paths and approach |
```

Then list all actions taken (labels applied, issues closed, comments added,
issues refined).

## Rules

- do not close issues unless clearly duplicate or resolved — when in doubt, keep open
- always comment before closing, citing the reason
- if an issue lacks enough context to triage, label it `needs-investigation`
- prefer merging duplicates into the older or more-detailed issue
- ask the user before closing more than 3 issues in a single run
