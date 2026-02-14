---
name: analyze-session
description: Analyze a session.db to identify agent friction, confusion, and errors. Recommend improvements to code, skills, docs, or prompts.
---

# analyze-session

Analyze one or more session.db files to find friction, confusion, and wasted
effort. Recommend concrete improvements.

## Usage

```
/skill:analyze-session <path-to-session.db> [<path2> ...]
```

If no path given, search for session.db files under `o/work/` and `.ah/*.db`
(the local session store).

## Steps

### 1. Locate session databases

```bash
# if paths provided, use those. otherwise search common locations:

# work phase session databases
find . -name "session.db" -type f 2>/dev/null

# .ah/ stores sessions as <ulid>.db (not session.db)
# list by recency, skip queue.db files
ls -t .ah/*.db 2>/dev/null | grep -v queue.db
```

When no paths are given, default to the most recent `.ah/*.db` file.
To analyze a specific session, pass its path. To analyze all recent sessions,
pass a glob like `.ah/*.db` or use `--last N` to analyze the N most recent.

### 2. Extract error signals

For each session.db, run these queries:

```bash
DB="<path>"

# schema sanity check
sqlite3 "$DB" ".tables"

# overview: message count, token totals, duration
sqlite3 -header "$DB" "
  SELECT
    count(*) as turns,
    sum(input_tokens) as total_input_tokens,
    sum(output_tokens) as total_output_tokens,
    (max(created_at) - min(created_at)) as duration_s
  FROM messages;"

# stop reasons — max_tokens or missing stop_reason signals problems
sqlite3 -header "$DB" "
  SELECT stop_reason, count(*) as n
  FROM messages WHERE role='assistant'
  GROUP BY stop_reason;"

# tool errors — the primary friction signal
# tool_input is on tool_use rows, tool_output/is_error on tool_result rows.
# they share the same tool_id.
sqlite3 -header "$DB" "
  SELECT tu.tool_name,
    substr(coalesce(
      json_extract(tu.tool_input, '$.path'),
      json_extract(tu.tool_input, '$.command')
    ), 1, 150) as target,
    substr(tr.tool_output, 1, 200) as error_output
  FROM content_blocks tr
  JOIN content_blocks tu ON tu.tool_id = tr.tool_id AND tu.block_type = 'tool_use'
  WHERE tr.block_type = 'tool_result' AND tr.is_error = 1;"

# slow operations (>10s)
sqlite3 -header "$DB" "
  SELECT tu.tool_name, tr.duration_ms,
    substr(coalesce(
      json_extract(tu.tool_input, '$.path'),
      json_extract(tu.tool_input, '$.command')
    ), 1, 150) as target
  FROM content_blocks tr
  JOIN content_blocks tu ON tu.tool_id = tr.tool_id AND tu.block_type = 'tool_use'
  WHERE tr.block_type = 'tool_result' AND tr.duration_ms > 10000
  ORDER BY tr.duration_ms DESC
  LIMIT 10;"

# repeated file reads — sign of confusion or missing context
sqlite3 -header "$DB" "
  SELECT json_extract(tool_input, '$.path') as path, count(*) as reads
  FROM content_blocks
  WHERE block_type='tool_use' AND tool_name='read'
  GROUP BY path
  HAVING reads > 1
  ORDER BY reads DESC;"

# repeated bash commands — sign of retries
sqlite3 -header "$DB" "
  SELECT json_extract(tool_input, '$.command') as cmd, count(*) as runs
  FROM content_blocks
  WHERE block_type='tool_use' AND tool_name='bash'
  GROUP BY cmd
  HAVING runs > 1
  ORDER BY runs DESC;"

# failed reads (tried to read files that don't exist)
sqlite3 -header "$DB" "
  SELECT json_extract(tu.tool_input, '$.path') as path,
    substr(tr.tool_output, 1, 150) as error
  FROM content_blocks tr
  JOIN content_blocks tu ON tu.tool_id = tr.tool_id AND tu.block_type = 'tool_use'
  WHERE tr.block_type = 'tool_result' AND tr.is_error = 1 AND tu.tool_name = 'read';"

# token usage per turn — spikes indicate large outputs or confusion
sqlite3 -header "$DB" "
  SELECT seq, role, input_tokens, output_tokens, stop_reason, api_latency_ms
  FROM messages
  WHERE role='assistant'
  ORDER BY seq;"
```

### 3. Extract behavioral signals

Look for confusion and wasted effort in assistant text:

```bash
# assistant text containing hedging, backtracking, or error recovery
sqlite3 "$DB" "
  SELECT m.seq, substr(cb.content, 1, 400)
  FROM content_blocks cb
  JOIN messages m ON cb.message_id = m.id
  WHERE cb.block_type='text'
    AND m.role='assistant'
    AND (
      cb.content LIKE '%let me try%'
      OR cb.content LIKE '%try again%'
      OR cb.content LIKE '%retry%'
      OR cb.content LIKE '%instead%I%'
      OR cb.content LIKE '%doesn''t exist%'
      OR cb.content LIKE '%not found%'
      OR cb.content LIKE '%doesn''t seem%'
      OR cb.content LIKE '%failed%'
      OR cb.content LIKE '%error%'
      OR cb.content LIKE '%unfortunately%'
      OR cb.content LIKE '%I apologize%'
      OR cb.content LIKE '%wrong%approach%'
      OR cb.content LIKE '%that didn''t work%'
      OR cb.content LIKE '%exit code%'
    )
  ORDER BY m.seq;"
```

### 4. Check events for additional context

```bash
# agent end events — check stop reason and total tokens
sqlite3 "$DB" "
  SELECT details FROM events
  WHERE event_type='agent_end';"

# state changes
sqlite3 "$DB" "
  SELECT details FROM events
  WHERE event_type='state_change';"

# error tool calls from events (has richer detail than content_blocks)
sqlite3 "$DB" "
  SELECT json_extract(details, '$.tool_name') as tool,
    json_extract(details, '$.tool_key') as key,
    json_extract(details, '$.is_error') as err
  FROM events
  WHERE event_type='tool_call_end'
    AND json_extract(details, '$.is_error')=1;"
```

### 5. Classify friction

Categorize each finding into one of these friction types:

| Type | Description | Example |
|------|-------------|---------|
| **hallucination** | agent assumed a file/path/flag exists that doesn't | read non-existent `lib/ah/loop.tl` |
| **retry-loop** | agent repeated the same failing action | 15 bash commands returning exit code 127 |
| **missing-context** | agent lacked info it needed, had to search | re-reading same file multiple times |
| **tool-failure** | tool returned an error outside agent's control | sandbox missing utilities |
| **token-waste** | disproportionate tokens spent on low-value work | 1800 output tokens for a simple write |
| **prompt-gap** | agent instructions were unclear or missing | no guidance on how to handle missing files |
| **wrong-approach** | agent took a suboptimal path, then corrected | tried complex approach before simple one |

### 6. Identify root causes and recommendations

For each friction, trace it to a root cause and recommend a fix:

- **code fix**: bug in tool implementation, harness, or CLI
- **skill improvement**: skill instructions missing a step or edge case
- **doc update**: README, system prompt, or phase prompt needs clarification
- **prompt fix**: phase prompt (plan.md, do.md, etc.) missing guidance
- **guardrail**: add validation or early-exit to prevent the failure class

### 7. Write output

Print a summary to stdout:

```
## Session analysis: <db path>

### Overview
- turns: N
- tokens: N in / N out
- duration: Ns
- errors: N
- model: <model>

### Friction found

#### 1. <title> (type: <type>)
**what happened**: <description>
**evidence**: <specific queries/data>
**impact**: <tokens wasted, time lost, or downstream effect>
**root cause**: <why this happened>
**recommendation**: <what to fix>
**fix target**: <code|skill|doc|prompt|guardrail>

#### 2. ...

### Recommended issues

| # | title | fix target | priority |
|---|-------|------------|----------|
| 1 | friction: <problem> | <target> | p0/p1/p2 |

### No-friction notes
<if run was clean, note what went well>
```

If `--json` flag was passed or an output path ending in `.json` was specified,
also write structured output:

```json
{
  "session": "<db path>",
  "overview": {
    "turns": 0,
    "input_tokens": 0,
    "output_tokens": 0,
    "duration_s": 0,
    "errors": 0,
    "model": ""
  },
  "frictions": [
    {
      "title": "friction: <problem>",
      "type": "<hallucination|retry-loop|missing-context|tool-failure|token-waste|prompt-gap|wrong-approach>",
      "description": "<what happened>",
      "evidence": "<specific data>",
      "impact": "<tokens/time/downstream>",
      "root_cause": "<why>",
      "recommendation": "<fix>",
      "fix_target": "<code|skill|doc|prompt|guardrail>",
      "priority": "<p0|p1|p2>"
    }
  ],
  "recommended_issues": [
    {
      "title": "friction: <concise problem>",
      "body": "## Problem\n<what happened>\n\n## Evidence\n<data from session>\n\n## Suggested fix\n<what to change>",
      "labels": ["friction"]
    }
  ]
}
```

## Rules

- only report real friction. if the session was clean, say so.
- maximum 5 friction items per session. prioritize by impact.
- every friction must cite specific evidence (query results, seq numbers, error text).
- don't count normal tool usage as friction — focus on errors, retries, and waste.
- a single failed read that the agent recovers from gracefully is minor. 15 repeated failures is a retry-loop.
- token-waste is relative: a 2000-token output for a simple file write is waste. a 2000-token output for a complex plan is normal.
- priority: p0 = blocks work or causes failure, p1 = significant waste, p2 = minor annoyance.
- when multiple sessions are analyzed, look for cross-session patterns.
