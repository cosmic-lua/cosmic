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

Record the source URL or file path for later reference.

### 2. Check for existing issues

Before creating new issues, search for existing issues that may already cover the friction points:

```bash
# Search open issues by keyword
gh issue list --repo owner/repo --state open --search "keyword" --json number,title,state

# List recent issues to check for duplicates
gh issue list --repo owner/repo --limit 50 --json number,title,state

# View a specific issue to check scope
gh issue view 123 --repo owner/repo
```

If an existing issue covers a friction point:
- Note it in the summary instead of creating a duplicate
- Consider commenting on the existing issue with new context from the friction log

### 3. Analyze and categorize findings

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

### 4. Design the issue breakdown

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

### 5. Write detailed issues

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
- [ ] #N description of blocking issue

## Source
- [Friction log title](URL to PR or file)
```

### 6. Create issues in dependency order

Create Tier 1 issues first (no blockers), then Tier 2+ issues that reference blockers.

**Capturing issue numbers:**
```bash
# Create issue and capture the URL (contains issue number)
gh issue create --repo owner/repo --title "Title" --body "Body"
# Output: https://github.com/owner/repo/issues/123
```

**Using task list syntax for tracking:**

GitHub tracks issues referenced in task lists. Use checkbox syntax for "Blocked by":

```bash
gh issue create --repo owner/repo --title "Add getpass wrapper" --body "$(cat <<'EOF'
## Problem
Users need a simple way to read passwords without echoing.

## Solution
Add unix.getpass() function.

## Blocked by
- [ ] #66 Add tcgetattr/tcsetattr (needed for terminal control)

## Source
- [Password vault friction report](https://github.com/owner/repo/pull/5)
EOF
)"
```

This creates a tracked relationship - GitHub shows the blocking issue's status.

**Full example with dependency chain:**

```bash
# Tier 1: No blockers
gh issue create --repo owner/repo --title "Add Database record types" --body "$(cat <<'EOF'
## Problem
Database methods are undocumented.

## Blocked by
None - this is a foundation issue.

## Source
- [Friction report](https://github.com/owner/repo/pull/5)
EOF
)"
# Returns: https://github.com/owner/repo/issues/65

# Tier 2: References #65
gh issue create --repo owner/repo --title "Index record methods in docs" --body "$(cat <<'EOF'
## Problem
Can't search for Database.exec in docs.

## Blocked by
- [ ] #65 Add Database record types (methods must exist before indexing)

## Source
- [Friction report](https://github.com/owner/repo/pull/5)
EOF
)"
```

### 7. Report summary

After creating all issues, provide:
- Table mapping friction points to issue numbers
- Dependency graph showing parallel work streams
- Starting points (Tier 1 issues with no blockers)
- Any existing issues that already covered friction points

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

**Blocked by**: Use task list format for GitHub tracking
- `- [ ] #N description` - GitHub tracks this and shows status
- Only reference direct blockers, not transitive dependencies

**Source**: Always link to the friction log
- Provides context and traceability
- Helps reviewers understand the user's original pain

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

- [ ] #65 Add Database and Statement record types (methods must exist to be indexed)

## Source

- [Password vault friction report](https://github.com/whilp/cosmic-eval/pull/5)
```

## Tips

- Always check for existing issues before creating new ones
- Create issues that can be worked on independently
- Keep implementation details specific enough to avoid ambiguity
- Use task list (`- [ ] #N`) format for blockers - GitHub tracks these
- Prefer smaller, focused issues over large omnibus issues
- Include code snippets that match the project's style
- Always include a Source link for traceability
