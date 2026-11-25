--- The record eval/report.tmpl writes the agent evals' report.md from, and the stages that write its numbers.
--- [`eval/agent.tl`] fills it.

local record Data
  --- One tool over every task.
  record Total
    --- The tool's name.
    tool: string
    --- The runs that passed.
    passed: integer
    --- The runs graded.
    n: integer
    --- Runs left out as unfit on the fixture, when there are any.
    unfit: integer?
    --- The mean cost of a run, in dollars.
    cost: number
    --- The mean tokens read from the cache in a run.
    cache_read: number
    --- The mean tokens written to the cache in a run.
    cache_write: number
    --- The mean output tokens of a run.
    output: number
    --- The cost of every run, in dollars.
    total: number
  end

  --- One tool on one task: means of a run.
  record Row
    --- The tool's name.
    tool: string
    --- "N of M passed", or "unfit on this fixture".
    grade: string
    --- Requests (turns).
    requests: number
    --- Cost, in dollars.
    cost: number
    --- Seconds of wall time.
    wall: number
    --- Seconds spent in requests.
    seconds: number
    --- Input tokens.
    input: number
    --- Output tokens.
    output: number
    --- Tokens read from the cache.
    cache_read: number
    --- Tokens the first request read from the cache.
    first_read: number
    --- Tokens written to the cache.
    cache_write: number
    --- Tool calls.
    tools: number
    --- Of them, `run` calls.
    runs: number
    --- Of them, snippets the checker refused.
    refused: number
    --- The checker's codes and how many runs each refused, most first, when any.
    refused_for: string?
    --- Each Host helper and the mean of snippets that name it, most first, when any.
    helpers: string?
  end

  --- One task's rows, a row a tool.
  record Task
    --- The task's name.
    name: string
    --- Each tool's row.
    rows: {Row}
  end

  --- The report.
  record Report
    --- The model the agent ran.
    model: string
    --- Runs of each task with each tool.
    reps: integer
    --- The fixture tree's name.
    fixture: string
    --- The tools given an effort, as "name level, ...", when any.
    effort: string?
    --- Each tool over every task.
    totals: {Total}
    --- Each task.
    tasks: {Task}
  end
end

--- `n` with no decimal.
function Data.fixed0(n: number): string
  return string.format("%.0f", n)
end

--- `n` with one decimal.
function Data.fixed1(n: number): string
  return string.format("%.1f", n)
end

--- `n` with three decimals.
function Data.fixed3(n: number): string
  return string.format("%.3f", n)
end

--- `n` with four decimals.
function Data.fixed4(n: number): string
  return string.format("%.4f", n)
end

return Data
