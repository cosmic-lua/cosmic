---
name: check
description: Review work execution against the plan. Validate changes, check for issues, render verdict.
---

# Check

You are checking a work item. Review the execution against the plan.

## Plan

{plan.md contents}

## Execution summary

{do.md contents}

## Instructions

1. Review the diff: `git diff main...HEAD`
2. Run validation steps from the plan
3. Check for unintended changes
4. Analyze friction from session databases:

        # for each existing phase db (plan, do):
        sqlite3 o/work/<phase>/session.db \
          "select tool_name, substr(tool_input,1,200), substr(tool_output,1,200) from content_blocks where is_error = 1;"
        sqlite3 o/work/<phase>/session.db \
          "select tool_name, duration_ms, substr(tool_input,1,200) from content_blocks where duration_ms > 30000 order by duration_ms desc limit 5;"
        sqlite3 o/work/<phase>/session.db \
          "select stop_reason, count(*) from messages where role='assistant' group by stop_reason;"

5. Write your assessment

## Output

Write `o/work/check/check.md`:

    # Check

    ## Plan compliance
    <did changes match plan?>

    ## Validation
    <results of running validation steps>

    ## Issues
    <problems found, grouped by severity>

    ### Critical
    <blocks merge, must fix. include file path and line number.>

    ### Warnings
    <should fix, not blocking. include file path and line number.>

    ### Suggestions
    <optional improvements>

    (write "none" for empty sections)

    ## Friction
    <friction identified from session database analysis: errors, slow operations,
     wasted retries, tool failures. cite specific evidence from the queries above.
     write "none" if the work was smooth.>

    ## Verdict
    <pass|needs-fixes|fail>

Write `o/work/check/actions.json`:

    {
      "verdict": "pass|needs-fixes|fail",
      "friction": ["<friction item>", ...],
      "actions": [
        {"action": "comment_issue", "body": "..."},
        {"action": "create_pr", "branch": "...", "title": "...", "body": "..."}
      ]
    }

Action rules:
- Always include `comment_issue` with verdict, summary, and any friction items
- Include `create_pr` only when verdict is "pass" and changes were committed
- `friction` array: one short string per friction item, or empty array if none
- Friction items must cite evidence from session database queries, not self-reports

Write `o/work/check/update.md`: 2-4 line summary.

Do NOT modify any source files.
