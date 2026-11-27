--- The record eval/report.tmpl writes the agent evals' report.md from, and the stages that write its numbers.
--- [`agent.tl`] fills it.

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
    --- Runs that ended with an error before their first request (left out of the passes above), when there are any.
    broken: integer?
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
    --- The mean of snippets that repeated the one before to the letter, when any did.
    resends: number?
    --- The mean of snippets that sorted, when any did.
    sorts: number?
    --- The first line of the error of a run that ended before its first request, when one did.
    broken: string?
  end

  --- One root cause of refused snippets, from one tool.
  record Cause
    --- "lang", "stdlib", "prompt" or "untagged": the layer whose change removes it.
    tag: string
    --- What it is.
    name: string
    --- The refused snippets it was named in.
    count: integer
    --- Each task that had it, with how often, most first.
    tasks: string
    --- The refused snippets it was named in, in the earlier round the run is set against, when there is one.
    was: integer?
  end

  --- One tool's refusals by root cause.
  record Causes
    --- The tool's name.
    tool: string
    --- The snippets the checker refused.
    refused: integer
    --- The runs they come from.
    runs: integer
    --- The causes of the refusals by layer ("lang 4, stdlib 2"), most first.
    layers: string
    --- Each cause, most first.
    causes: {Cause}
    --- The same line of the earlier round the run is set against ("N refused snippets in M runs; by layer: ..."), when there is one.
    was: string?
  end

  --- One name a tool's agent tried that does not exist.
  record Guess
    --- The name and the code the checker gave ("Json.string_of (field_unknown)").
    name: string
    --- The runs that tried it.
    runs: integer
    --- Each task that had it, with how often, most first.
    tasks: string
  end

  --- One tool's guessed names.
  record Guesses
    --- The tool's name.
    tool: string
    --- The names, most tried first.
    names: {Guess}
    --- How many more there are than are listed, when there are.
    more: integer?
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
    --- Says the fixture's AGENTS.md and CLAUDE.md were left out, when they were.
    agents_md?: string
    --- Each tool's refusals by root cause, for the tools that had any.
    causes: {Causes}
    --- Each tool's guessed names, for the tools that had any.
    guesses: {Guesses}
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
