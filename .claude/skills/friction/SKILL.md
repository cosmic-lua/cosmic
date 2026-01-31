---
name: friction
description: Convert friction logs into GitHub issues. Use when processing developer experience feedback, friction logs, user feedback PRs, or breaking down UX pain points into actionable tasks.
---

# friction

Convert friction logs and developer experience feedback into well-structured GitHub issues.

## When to use

- User shares a friction log (PR, markdown file, or inline text)
- User wants to break down DX feedback into implementable tasks
- User asks to create issues from user feedback or pain points

## Workflow

### 1. Gather the friction log

Accept input in any of these formats:
- **GitHub PR URL**: Fetch the PR description and comments using `gh pr view <url> --json body,comments`
- **File path**: Read the markdown file directly
- **Inline text**: User pastes the friction log content

### 2. Analyze and categorize findings

Read through the friction log and identify:

**What already exists (but isn't well documented)**
- Features users couldn't find
- APIs that exist but aren't discoverable

**What's actually missing**
- Missing functionality
- Missing documentation
- Missing tooling

**Pain points by category**
- Documentation gaps
- API ergonomics
- CLI experience
- Error messages
- Discoverability

### 3. Design the issue breakdown

Create a tiered structure based on dependencies:

```
Tier 1: Foundation (no blockers)
  - Core functionality that other work depends on
  - Type definitions and data structures

Tier 2: Infrastructure
  - Parsers, indexers, core systems
  - Blocked by Tier 1

Tier 3: Features
  - User-facing features built on infrastructure
  - Blocked by Tier 2

Tier 4+: Refinements
  - Polish, additional content, advanced features
  - Blocked by earlier tiers
```

### 4. Write detailed issues

Each issue must include:

```markdown
## Problem
[What's wrong / what's missing - from the user's perspective]

## Solution
[High-level approach]

## Files to modify
- path/to/file1
- path/to/file2

## Implementation details
[Code snippets, specific approach, patterns to follow]

## Acceptance criteria
- [ ] Specific testable criterion
- [ ] Another criterion
- [ ] Tests pass: `make test`

## Blocked by
- #N (if applicable)
```

### 5. Create issues in dependency order

Create issues starting from Tier 1, capturing issue numbers as you go:

```bash
# Create issue and capture number
gh issue create --repo owner/repo --title "Title" --body "$(cat <<'EOF'
Body content here...

## Blocked by
- #45 (previously created issue)
EOF
)"
```

### 6. Report summary

After creating all issues, provide:
- Table mapping plan items to issue numbers
- Dependency graph showing parallel work streams
- Starting points (issues with no blockers)

## Issue writing guidelines

**Titles**: Short, action-oriented
- "Add cosmic.json wrapper module"
- "Parse record type methods in docindex"

**Problem section**: User's perspective, not implementation details
- "Users don't know about cosmo.DecodeJson"
- "Can't search for Database.exec method"

**Implementation details**: Enough to work independently
- Include code snippets with actual types and signatures
- Reference existing patterns in the codebase
- Specify file paths

**Acceptance criteria**: Testable, specific
- "cosmic-lua --docs Database finds cosmo.lsqlite3.Database"
- "make test passes"

## Example issue

```markdown
## Problem

Users can't find documentation for record type methods. `--docs exec` doesn't find `Database.exec`.

## Solution

Index record methods in the doc system as `module.RecordName.method`.

## Files to modify

- `lib/cosmic/doc.tl` - extract methods from records
- `lib/cosmic/docindex.tl` - add methods to search index

## Implementation details

Update `parse_dtl()` to capture record methods:

\```teal
-- When parsing "local record Database", extract:
-- - record name
-- - each method with signature and doc comment
module.records[recordName].methods[methodName] = {sig, doc}
\```

Flatten into index:
\```teal
index["cosmo.lsqlite3.Database.exec"] = method_doc
\```

## Acceptance criteria

- [ ] `cosmic-lua --docs exec` finds `cosmo.lsqlite3.Database.exec`
- [ ] Record methods appear in search results
- [ ] `make test` passes

## Blocked by

- #46 (needs record definitions to exist)
```

## Tips

- Create issues that can be worked on independently
- Keep implementation details specific enough to avoid ambiguity
- Use "Blocked by" references to show dependencies clearly
- Prefer smaller, focused issues over large omnibus issues
- Include code snippets that match the project's style
