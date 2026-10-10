--- [`eval/result.tl`] over transcripts built here: the status words, the
--- numbers read from the `init` and `result` events, and `null` for
--- what a run does not supply.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Result = require("eval.result")
local stand_in = require("build.stand_in")

local function line(value: {string: any}): string
  return (assert(Json.encode(value)))
end

local function lines(list: {string}): string
  return table.concat(list, "\n") .. "\n"
end

local init <const> = line({ type = "system", subtype = "init", model = "claude-x",
  claude_code_version = "9.9.9", tools = { "Bash", "Read" }, skills = {},
  mcp_servers = { { name = "m", status = "connected" } } })
local call <const> = line({ type = "assistant", message = { content = {
  { type = "tool_use", id = "1", name = "Bash", input = {} },
  { type = "tool_use", id = "2", name = "Read", input = {} } } } })

local function finished(subtype: string, is_error: boolean): string
  return line({ type = "result", subtype = subtype, is_error = is_error, num_turns = 12,
    total_cost_usd = 0.5, usage = { input_tokens = 10, output_tokens = 20,
      output_tokens_details = { thinking_tokens = 7 },
      cache_creation_input_tokens = 30, cache_read_input_tokens = 40 } })
end

local files <const>: Result.Files = { started_at = "2026-01-01T00:00:00Z\n",
  finished_at = "2026-01-01T00:02:30Z\n", exit_code = "0\n" }

local function test_a_finished_run_reports_its_numbers()
  local fields = Result.build(lines({ init, call, finished("success", false) }), files,
    { exit_code = 0 }, { model = "asked", max_turns = 150, timeout = 600, commit = "abc" })
  assert(fields.status == "completed", tostring(fields.status))
  assert(fields.is_error == false, "false is a value, not null: " .. tostring(fields.is_error))
  assert(fields.thinking_tokens == 7, tostring(fields.thinking_tokens))
  assert(fields.model == "claude-x" and fields.claude_code_version == "9.9.9")
  assert(fields.turns == 12 and fields.tool_calls == 2 and fields.cost_usd == 0.5)
  assert(fields.elapsed_seconds == 150, tostring(fields.elapsed_seconds))
  assert(fields.input_tokens == 10 and fields.output_tokens == 20)
  assert(fields.cache_creation_input_tokens == 30 and fields.cache_read_input_tokens == 40)
  assert(fields.grade_verdict == "PASS" and fields.grade_exit_code == 0)
  assert(fields.max_turns == 150 and fields.commit == "abc")
  local tools = fields.tools as {string}
  assert(tools[2] == "Read")
end

local function test_the_cli_cap_the_deadline_and_an_error_each_have_a_status()
  local capped = Result.build(lines({ init, finished("error_max_turns", true) }), files, {})
  assert(capped.status == "turn_cap", tostring(capped.status))
  local cut = Result.build(lines({ init, call }), files, {})
  assert(cut.status == "no_result", tostring(cut.status))
  local crashed = Result.build(lines({ init, call }), { exit_code = "1\n" }, {})
  assert(crashed.status == "no_result", tostring(crashed.status))
  assert(Result.build(lines({ init, call }), { exit_code = "124\n" }, {}).status == "timeout")
  local killed: Result.Files = { exit_code = "124\n" }
  assert(Result.build(lines({ init, finished("success", false) }), killed, {}).status == "timeout")
  local broke = Result.build(lines({ init, finished("success", true) }), files, {})
  assert(broke.status == "api_error", tostring(broke.status))
  local died = Result.build(lines({ init, finished("error_during_execution", true) }), files, {})
  assert(died.status == "api_error", tostring(died.status))
end

local function test_what_a_run_does_not_supply_is_null_not_zero()
  local fields = Result.build(nil, {}, {})
  for _, key in ipairs({ "turns", "tool_calls", "cost_usd", "input_tokens", "thinking_tokens",
      "elapsed_seconds", "model", "tools", "grade_exit_code", "grade_verdict", "transcript",
      "contamination", "claude_code_version" }) do
    assert(fields[key] == Json.null, key .. " is " .. tostring(fields[key]))
  end
  local plain = line({ type = "result", subtype = "success", is_error = false, num_turns = 1,
    usage = { output_tokens = 3 } })
  local partial = Result.build(lines({ init, plain }), files, {})
  assert(partial.thinking_tokens == Json.null, "no thinking figure was reported")
end

local function test_the_grader_exit_status_names_its_verdict()
  assert(Result.verdict(0) == "PASS" and Result.verdict(1) == "FAIL")
  assert(Result.verdict(124) == "TIMEOUT" and Result.verdict(2) == "ERROR")
end

local function test_the_summary_decides_contamination()
  local clean = Result.build(nil, { summary = "turns=1\n" }, {})
  assert((clean.contamination as {string})[1] == nil)
  local dirty = Result.build(nil, { summary = "turns=1\nBREACH: /home/x\nsandbox-tmp: 2\n" }, {})
  assert((dirty.contamination as {string})[1] == "BREACH: /home/x")
end

local function test_the_encoding_is_json_in_the_readmes_order()
  local text = assert(Result.encode(Result.build(lines({ init, finished("success", false) }), files,
    { exit_code = 1, log = "grades/1/grade.log" })))
  local back = assert(Json.decode(text)) as {string: any}
  assert(back.runner == "claude" and back.grade_verdict == "FAIL" and back.turns == 12)
  assert(back.reasoning_effort == nil, "null reads back as absent")
  assert(text:find('"runner"', 1, true) < text:find('"status"', 1, true))
  assert(text:find('"reasoning_effort": null', 1, true), text)
  local clean = assert(Result.encode(Result.build(nil, { summary = "turns=1\n" }, {})))
  assert(clean:find('"contamination": []', 1, true), "nothing flagged is an empty list, not {}")
end

--- git is found on the PATH given, not run as a bare name, which
--- Child.run would not search for.
local function test_the_harness_commit_comes_from_the_git_on_the_path(dir: string)
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(stand_in.place(probe, dir .. "/bin/git", "print 0123456789abcdef0123456789abcdef01234567"))
  assert(Result.git_head("/anywhere", dir .. "/bin") == "0123456789abcdef0123456789abcdef01234567")
  assert(Result.git_head("/anywhere", dir .. "/nowhere") == nil)
end
