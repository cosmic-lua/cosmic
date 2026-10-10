--- The result.json of one eval run, built from what [`eval/solve`] and the
--- grader left in the arena: the transcript's `init` and final `result`
--- events, the timestamps and exit status beside PROMPT.md, and the
--- grade. The fields are eval/README.md's "reporting a run"; a value
--- the run does not supply is `null`, never 0.
---
---     cosmic --standalone eval/result.tl <arena> [--grade-exit N] [--model M]
---         [--commit C] [--max-turns N] [--timeout S]
---
--- It writes <arena>/result.json. [`eval/result`] runs this on the
--- bootstrap cosmic, as [`eval/solve`] runs eval/solve.tl: it requires
--- `cosmic.*` modules only.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local record Result
  --- What the arena holds beside the transcript, each nil where it is
  --- not there.
  record Files
    --- The transcript's text.
    transcript: string
    started_at: string
    finished_at: string
    --- The solver's exit status, as text.
    exit_code: string
    --- eval/summarize's report.
    summary: string
  end

  --- What the grader said: its exit status, nil when it did not run.
  record Grade
    exit_code: integer
    --- The log that holds its lines, as a path under the arena.
    log: string
  end

  --- What the caller knows that the arena does not.
  record Meta
    model: string
    max_turns: integer
    timeout: integer
    --- The commit of the binary under test.
    commit: string
    --- The commit of this harness.
    harness_commit: string
  end
end

--- The order the fields are written in.
local ORDER <const>: {string} = {
  "runner", "model", "reasoning_effort", "claude_code_version", "commit", "harness_commit",
  "started_at", "finished_at", "elapsed_seconds", "status", "deadline_method", "max_turns",
  "timeout_seconds", "exit_code", "result_subtype", "is_error", "grade_exit_code", "grade_verdict",
  "grade_log", "contamination", "transcript", "turns", "tool_calls", "cost_usd", "input_tokens",
  "output_tokens", "thinking_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
  "tools", "skills", "mcp_servers",
}

local function decode(line: string): {string: any} | nil
  local value, _ = Json.decode(line, { max_depth = 1000, lone_surrogates = true })
  if value is {string: any} then return value end
  return nil
end

--- `event[key]`, [`Json.null`] where there is no event or no such key
--- (a `false` is a value).
local function reported_field(event: {string: any} | nil, key: string): any
  if event == nil or event[key] == nil then return Json.null end
  return event[key]
end

local function number(value: any): any
  if value is number then return value end
  return Json.null
end

local function stamp(text: string | nil): integer | nil
  if text == nil then return nil end
  local ns, _ = Time.parse_rfc3339((text:gsub("%s+$", "")))
  return ns
end

local function integer_of(text: string | nil): integer | nil
  if text == nil then return nil end
  return math.tointeger(tonumber((text:gsub("%s+$", ""))))
end

--- The word for how the run ended: `timeout` when the solver's status
--- was 124, `no_result` when no `result` event closes the transcript
--- under any other status (a crash), `turn_cap` when the CLI stopped at
--- --max-turns, `api_error` when it reports an error of any other kind,
--- else `completed`.
local function status_of(exit_code: integer | nil, result: {string: any} | nil): string
  if exit_code == 124 then return "timeout" end
  if result == nil then return "no_result" end
  if result["subtype"] == "error_max_turns" then return "turn_cap" end
  local subtype = result["subtype"]
  if result["is_error"] == true or (subtype ~= nil and subtype ~= "success") then
    return "api_error"
  end
  return "completed"
end

--- The grade's verdict word for its exit status: PASS, FAIL, TIMEOUT
--- (the grader's deadline) or ERROR for any other (a usage error).
function Result.verdict(code: integer | nil): any
  if code == nil then return Json.null end
  if code == 0 then return "PASS" end
  if code == 1 then return "FAIL" end
  if code == 124 then return "TIMEOUT" end
  return "ERROR"
end

--- The result.json fields, as a table with [`Json.null`] for each value
--- that is unavailable, for a transcript's text (nil when there is
--- none), the arena's `files`, the `grade` and what the caller knows.
function Result.build(transcript: string | nil, files: Result.Files, grade: Result.Grade,
                      meta?: Result.Meta): {string: any}
  meta = meta or {}
  local init: {string: any} = nil
  local result: {string: any} = nil
  local tool_calls = 0
  if transcript ~= nil then
    for line in transcript:gsub("\r\n?", "\n"):gmatch("[^\n]+") do
      local event = decode(line)
      if event ~= nil then
        local kind = event["type"]
        if kind == "system" and event["subtype"] == "init" then
          init = event
        elseif kind == "result" then
          result = event
        elseif kind == "assistant" then
          local message = event["message"]
          local content: any = message is {string: any} and message["content"] or nil
          if content is {any} then
            for _, part in ipairs(content) do
              if part is {string: any} and part["type"] == "tool_use" then
                tool_calls = tool_calls + 1
              end
            end
          end
        end
      end
    end
  end
  local usage: {string: any} = {}
  local reported: any = result ~= nil and result["usage"] or nil
  if reported is {string: any} then
    usage = reported
  end
  local detailed: any = usage["output_tokens_details"]
  local details: {string: any} = detailed is {string: any} and detailed or {}
  local function from_init(key: string): any
    if init == nil or init[key] == nil then return Json.null end
    return init[key]
  end
  local exit_code = integer_of(files.exit_code)
  local started, finished = stamp(files.started_at), stamp(files.finished_at)
  local elapsed: any = Json.null
  if started ~= nil and finished ~= nil and finished >= started then
    elapsed = (finished - started) // 1000000000
  end
  local contamination: any = Json.null
  if files.summary ~= nil then
    local flagged: {string} = {}
    for line in files.summary:gmatch("[^\n]+") do
      if line:sub(1, 8) == "BREACH: " or line:sub(1, 15) == "CONTAMINATION: " then
        flagged[#flagged + 1] = line
      end
    end
    contamination = Json.array(flagged)
  end
  local function text_or_null(value: string | nil): any
    if value == nil then return Json.null end
    return (value:gsub("%s+$", ""))
  end
  local out: {string: any} = {
    runner = "claude",
    model = from_init("model") ~= Json.null and from_init("model") or meta.model or Json.null,
    reasoning_effort = Json.null,
    claude_code_version = from_init("claude_code_version"),
    commit = meta.commit or Json.null,
    harness_commit = meta.harness_commit or Json.null,
    started_at = text_or_null(files.started_at),
    finished_at = text_or_null(files.finished_at),
    elapsed_seconds = elapsed,
    status = status_of(exit_code, result),
    deadline_method = "eval/solve",
    max_turns = meta.max_turns or Json.null,
    timeout_seconds = meta.timeout or Json.null,
    exit_code = exit_code or Json.null,
    result_subtype = reported_field(result, "subtype"),
    is_error = reported_field(result, "is_error"),
    grade_exit_code = grade.exit_code or Json.null,
    grade_verdict = Result.verdict(grade.exit_code),
    grade_log = grade.log or Json.null,
    contamination = contamination,
    transcript = transcript ~= nil and "transcript.jsonl" or Json.null,
    turns = result ~= nil and number(result["num_turns"]) or Json.null,
    tool_calls = transcript ~= nil and tool_calls or Json.null,
    cost_usd = result ~= nil and number(result["total_cost_usd"]) or Json.null,
    input_tokens = number(usage["input_tokens"]),
    output_tokens = number(usage["output_tokens"]),
    -- output_tokens includes thinking; the CLI breaks it out in
    -- usage.output_tokens_details.thinking_tokens.
    thinking_tokens = number(details["thinking_tokens"]),
    cache_creation_input_tokens = number(usage["cache_creation_input_tokens"]),
    cache_read_input_tokens = number(usage["cache_read_input_tokens"]),
    tools = from_init("tools"),
    skills = from_init("skills"),
    mcp_servers = from_init("mcp_servers"),
  }
  return out
end

--- `fields` as JSON text in the README's order, one field a line.
function Result.encode(fields: {string: any}): string | nil, string
  local lines: {string} = {}
  for _, key in ipairs(ORDER) do
    local value = fields[key]
    if value == nil then value = Json.null end
    local text, why = Json.encode(value, { max_depth = 100 })
    if text == nil then return nil, key .. ": " .. why end
    lines[#lines + 1] = "  " .. (assert(Json.encode(key))) .. ": " .. text
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n}\n", ""
end

local function complain(message: string)
  local _, _ = Fs.put(Fs.stderr, "result: " .. message .. "\n")
end

local USAGE <const> = "usage: eval/result <arena> [--grade-exit N] [--grade-log PATH] [--model M] " ..
  "[--commit C] [--max-turns N] [--timeout S]"

--- The harness commit: `git rev-parse HEAD` in `repo`, with git found
--- on `path` (PATH by default) -- Child.run does not search PATH --
--- nil where git or the repository is not there.
function Result.git_head(repo: string, path?: string): string | nil
  local git, _ = Proc.find("git", path)
  if git == nil then return nil end
  local ran, _ = Child.run({ git, "-C", repo, "rev-parse", "HEAD" },
    { stdout = "capture", stderr = "null", stdin = "null", timeout_ns = Clock.seconds(10) })
  local sha = ran ~= nil and ran.ok and (ran.stdout or ""):match("^(%x+)\n$") or nil
  return sha
end

function Result.main(argv: {integer: string}): integer
  local arena: string = nil
  local grade: Result.Grade = {}
  local meta: Result.Meta = {}
  local i = 1
  while argv[i] ~= nil do
    local word = argv[i]
    if word:sub(1, 2) == "--" then
      local value = argv[i + 1]
      if value == nil then
        complain(word .. " needs a value")
        return 2
      end
      if word == "--grade-exit" then
        grade.exit_code = integer_of(value)
        if grade.exit_code == nil then
          complain(word .. " takes an integer")
          return 2
        end
      elseif word == "--grade-log" then
        grade.log = value
      elseif word == "--model" then
        meta.model = value
      elseif word == "--commit" then
        meta.commit = value
      elseif word == "--max-turns" or word == "--timeout" then
        local n = integer_of(value)
        if n == nil or n < 1 then
          complain(word .. " takes a positive integer")
          return 2
        end
        if word == "--timeout" then meta.timeout = n else meta.max_turns = n end
      else
        complain("unknown option " .. word)
        return 2
      end
      i = i + 2
    elseif arena == nil then
      arena = word
      i = i + 1
    else
      complain(USAGE)
      return 2
    end
  end
  if arena == nil then
    complain(USAGE)
    return 2
  end
  local absolute, trouble = Fs.absolute(arena)
  if absolute == nil then
    complain(trouble)
    return 2
  end
  arena = absolute
  local script, strouble = Fs.absolute(argv[0])
  if script == nil then
    complain(strouble)
    return 2
  end
  local repo = script:match("^(.*)/eval/[^/]+%.tl$")
  if repo ~= nil then meta.harness_commit = Result.git_head(repo) end
  local function read(name: string): string | nil
    local text, _ = Fs.read(arena .. "/" .. name)
    return text
  end
  local files: Result.Files = {
    transcript = read("transcript.jsonl"), started_at = read("started_at"),
    finished_at = read("finished_at"), exit_code = read("exit_code"), summary = read("summary.txt"),
  }
  local text, why = Result.encode(Result.build(files.transcript, files, grade, meta))
  if text == nil then
    complain(why)
    return 1
  end
  local wrote, wtrouble = Fs.write(arena .. "/result.json", text)
  if not wrote then
    complain(wtrouble)
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, "result: " .. arena .. "/result.json\n")
  return 0
end

return Result
