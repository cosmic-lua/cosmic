--- The tools as values: run, the one an agent offers, and a tool of one's own.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ env = { "TMPDIR" } }

local keyed = agent_fixture.keyed
local scratch = agent_fixture.scratch

local function test_a_run_that_ended_in_a_call_is_settled()
  local db = assert(Sessions.open(scratch() .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local s = Agent.new({ model = "m", effort = "low", sign = keyed("k"), system = "", cwd = "/", db = db, id = id,
    messages = {
      { role = "user", content = "go" },
      { role = "assistant", content = { { type = "tool_use", id = "t9", name = "bash", input = { command = "x" } } } },
    } })
  assert(s:settle())
  assert(#s.messages == 3 and assert(Json.encode(s.messages[3])):find('"tool_use_id":"t9"', 1, true) ~= nil)
  assert(s:settle() and #s.messages == 3)
  local loaded = assert(Sessions.load(db, id))
  assert(#loaded.messages == 1 and loaded.model == "m")
  local _, _ = db:close()
end

local function names(tools: {Tools.Tool}): string
  local out: mut {string} = {}
  for _, t in ipairs(tools) do out[#out + 1] = t.name end
  return table.concat(out, " ")
end

local function test_the_run_description_is_its_template_filled()
  local tool = assert(Tools.find(Tools.all(), "run"), "run is a tool")
  -- The slot is filled, and `{{` written as text in the template stands as it is.
  assert(tool.description:find("(its start and end past 8KB)", 1, true) ~= nil, tool.description)
  assert(tool.description:find("-> {{path, line, text}}:", 1, true) ~= nil, tool.description)
  assert(tool.description:find("^Run a program in cosmic, ") ~= nil, tool.description)
  -- No line ending after the example's last line, as the words were before the template.
  assert(tool.description:sub(-4) == " end", tool.description)
end

local function test_tools_are_values_to_pick_and_make()
  assert(names(Tools.all()) == "run", names(Tools.all()))
  -- Run tells the model how to read what is kept.
  local run_tool = assert(Tools.find(Tools.all(), "run"))
  assert(run_tool.description:find("Host.history(query)", 1, true) ~= nil and
      run_tool.description:find("Tables: sessions", 1, true) ~= nil, run_tool.description)
  assert(table.concat(run_tool.guidelines, " "):find("Host.output(id)", 1, true) ~= nil)
  local unknown = Tools.dispatch(Tools.all(), "bash", { command = "true" }, { cwd = "/" }).text
  assert(unknown == "Tool bash not found: the tools are run", unknown)
  -- Each call gives a new list: a change to one is not seen in the next.
  local mine = Tools.all()
  table.remove(mine, 1)
  assert(#Tools.all() == 1 and #mine == 0)
  -- A tool of one's own: offered to the model, and run when it calls it.
  local none: {string: Json.Value} = {}
  local now: Tools.Tool = { name = "now", snippet = "Say the time", guidelines = { "Ask now for the time." },
    description = "The time.", schema = { type = "object", properties = none },
    run = function(_: Tools.Object, c: Tools.Context): Tools.Result
      return { text = "noon in " .. c.cwd, is_error = false }
    end }
  local a = agent_fixture.api({ { content = { { type = "tool_use", id = "t1", name = "now", input = none },
    { type = "tool_use", id = "t2", name = "bash", input = { command = "true" } } }, stop_reason = "tool_use" },
    { content = { { type = "text", text = "ok" } }, stop_reason = "end_turn" } })
  local s = Agent.new({ sign = keyed("k"), cwd = "/", base_url = "https://api.test", send = a.send, tools = { now } })
  assert(s.system:find("- now: Say the time", 1, true) ~= nil and s.system:find("- Ask now for the time.", 1, true) ~= nil)
  assert(s.system:find("bash", 1, true) == nil, s.system)
  assert(s:prompt("what time is it?"))
  local listed = agent_fixture.sent(a, 1)["tools"]
  assert(listed ~= nil)
  local offered = assert(Json.encode(listed))
  assert(offered == '[{"cache_control":{"type":"ephemeral"},"description":"The time.","input_schema":{"properties":{},"type":"object"},"name":"now"}]', offered)
  local answers = agent_fixture.said(a, 2)
  assert(answers:find('"content":"noon in /"', 1, true) ~= nil, answers)
  assert(answers:find("Tool bash not found", 1, true) ~= nil, answers)
end

--- The definitions the API is shown: the last is the cache breakpoint, which every session's prefix shares; run names
--- Host.bash only where a snippet may run programs.
local function test_the_definitions_mark_the_cache_and_name_host_bash_with_commands()
  local shown = assert(Json.encode(Tools.definitions(Tools.all())))
  local _, marks = shown:gsub('"cache_control"', "")
  assert(marks == 1 and shown:find('"cache_control":{"type":"ephemeral"},"description":"Run', 1, true) ~= nil, shown)
  assert(shown:find("Host.bash", 1, true) == nil, shown)
  assert(assert(Json.encode(Tools.definitions(Tools.all(), true))):find("Host.bash", 1, true) ~= nil)
end
