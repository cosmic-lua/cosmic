---
name: project
description: Work from the GitHub project board using a pull-based workflow. Use when starting work, picking tasks, or managing WIP limits.
user_invocable: true
---

# project

Pull-based workflow from the GitHub project board.

## Principles

1. **Work backwards**: Start from "ready" and work back to "next"
2. **Respect WIP limits**: Don't start new work if columns are at capacity
3. **Pull, don't push**: Only move items when there's capacity downstream
4. **Never approve or merge PRs**: Claude must never run `gh pr review --approve` or `gh pr merge`. Only humans approve and merge.

## Column limits

| Column | Limit | Description |
|--------|-------|-------------|
| next | 3 | Prioritized, ready to start |
| In Progress | 1 | Active work |
| ready | 2 | Ready for review |

## Workflow

### 1. Check project state

```bash
gh api graphql -f query='
{
  user(login: "whilp") {
    projectV2(number: 2) {
      items(first: 50) {
        nodes {
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
            }
          }
          content {
            ... on Issue {
              number
              title
              labels(first: 5) { nodes { name } }
            }
            ... on PullRequest {
              number
              title
            }
          }
        }
      }
    }
  }
}' | jq -r '
  .data.user.projectV2.items.nodes
  | group_by(.fieldValueByName.name)
  | map({
      status: .[0].fieldValueByName.name,
      count: length,
      items: map(.content | "\(.number): \(.title)")
    })
  | sort_by(.status)
  | .[]
  | "\(.status) (\(.count)):", (.items[] | "  - \(.)")
'
```

### 2. Work the board (in order)

Work through these steps in order, stopping when you find actionable work:

1. **Check ready column**
   - Note PRs awaiting human review
   - Use `gh pr list` to see what's ready
   - **Do not** approve or merge PRs - only humans do this

2. **Start work (if In Progress has capacity)**
   - If In Progress < 1, pull top item from "next"
   - Skip blocked issues (check for `blocked` label)
   - **Before starting any implementation:**
     1. Re-check the board state to confirm the issue is still available (someone else may have picked it up)
     2. Move the issue to "In Progress" and verify the move succeeded
     3. Only then begin implementation work

3. **Refill next (if next has capacity)**
   - If next < 3, promote top item from "Todo"
   - Items should be prioritized in Todo before promotion

4. **Refine next items**
   - Review items in "next" column
   - Add context, clarify scope, or refine the plan
   - Ensure issues are ready to start when pulled

5. **Prioritize Todo**
   - Review and reorder Todo items by priority
   - Move blocked items to the bottom
   - Group related items together
   - Ensure top items are ready to promote to "next"

### 3. Move items

Use this to move an issue to a new status:

```bash
# Get item ID for an issue
ITEM_ID=$(gh api graphql -f query='
{
  user(login: "whilp") {
    projectV2(number: 2) {
      items(first: 100) {
        nodes {
          id
          content { ... on Issue { number } }
        }
      }
    }
  }
}' | jq -r '.data.user.projectV2.items.nodes[] | select(.content.number == ISSUE_NUM) | .id')

# Move to new status
gh api graphql -f query='
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "PVT_kwHOAALlm84BOBd9"
    itemId: "'$ITEM_ID'"
    fieldId: "PVTSSF_lAHOAALlm84BOBd9zg82K90"
    value: { singleSelectOptionId: "OPTION_ID" }
  }) {
    projectV2Item { id }
  }
}'
```

Status option IDs:
- Todo: `f75ad846`
- next: `795c78fd`
- In Progress: `47fc9ee4`
- ready: `5d0e1caf`
- Done: `98236657`

### 4. Reorder items

Use position mutation to reorder items within a column:

```bash
# Move item to top of its column
gh api graphql -f query='
mutation {
  updateProjectV2ItemPosition(input: {
    projectId: "PVT_kwHOAALlm84BOBd9"
    itemId: "'$ITEM_ID'"
    afterId: null
  }) {
    items(first: 1) { nodes { id } }
  }
}'
```

## Quick commands

```bash
# Show board summary
gh project item-list 2 --owner whilp --format json | jq 'group_by(.status) | map({status: .[0].status, count: length})'

# Show what's blocked
gh issue list --label blocked --json number,title

# Show what's ready for review
gh pr list --json number,title,reviewDecision

# Show next items (excluding blocked)
gh api graphql -f query='...' | jq '
  .data.user.projectV2.items.nodes
  | map(select(.fieldValueByName.name == "next"))
  | map(select(.content.labels.nodes | map(.name) | contains(["blocked"]) | not))
  | map(.content | "\(.number): \(.title)")
'
```

## Integration with work

When working on a task:
1. Run `/project` to check board state
2. Follow "Work the board" steps in order
3. **Before writing any code**: move issue to "In Progress" and verify the move
4. Only after confirming the issue is in "In Progress", begin implementation
5. Open PR when ready, move to "ready"
6. After merge, move to "Done"

**Important**: Always re-check the board before claiming an issue. Someone else may have moved it since you last checked.

When reviewing the board:
1. Check capacity in each column
2. Note items in "ready" awaiting human review (do not approve or merge)
3. Refill columns that have capacity
4. Refine and prioritize upcoming work
