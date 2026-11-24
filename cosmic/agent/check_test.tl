--- An agent's before and after hooks, and the checks of cosmic.agent.check.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Check = require("cosmic.agent.check")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ env = { "TMPDIR" }, profiles = { "system" } }

local keyed = agent_fixture.keyed
local said = agent_fixture.said
local scratch = agent_fixture.scratch

--- A tool call to make: the tool's name and its input.
local record Asked
  name: string
  input: Json.Value
end

--- A reply that calls each of `calls`.
local function calling(calls: {Asked}): Json.Value
  local content: mut {Json.Value} = {}
  for i, c in ipairs(calls) do
    content[#content + 1] = { type = "tool_use", id = "t" .. tostring(i), name = c.name, input = c.input }
  end
  return { content = Json.array(content), stop_reason = "tool_use" }
end

local DONE <const>: Json.Value = { content = { { type = "text", text = "done" } }, stop_reason = "end_turn" }

local function test_checks_block_calls_and_after_changes_results()
  local dir = scratch()
  assert(Fs.write(dir .. "/a.txt", "the secret is 42"))
  assert(Fs.write(dir .. "/b.txt", "more"))
  local a = agent_fixture.api({ calling({
    { name = "read", input = { path = "a.txt" } },
    { name = "read", input = { path = "b.txt" } },
    { name = "write", input = { path = "c.txt", content = "no" } },
  }), DONE })
  local s = Agent.new({ sign = keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send, system = "",
    tools = Tools.only(Tools.all(), { "read", "write" }) })
  s.before = Check.all({
    Check.only({ "read", "write" }),
    Check.paths({ grants = { { path = dir, letters = "r" } } }),
    Check.budget({ read = 1 }),
  })
  local seen: mut {Agent.Call} = {}
  s.after = function(call: Agent.Call, result: Tools.Result): Tools.Result?
    seen[#seen + 1] = call
    if result.text:find("secret", 1, true) ~= nil then
      return { text = "[redacted]", is_error = false }
    end
    return nil
  end
  local blocked: mut {string} = {}
  s.on = function(e: Agent.Event)
    if e.kind == "blocked" then blocked[#blocked + 1] = e.name .. ": " .. e.reason end
    if e.kind == "text" then error("a bug in the UI") end
  end
  assert(s:prompt("go"))
  local answers = said(a, 2)
  assert(answers:find('"content":"[redacted]"', 1, true) ~= nil and answers:find("42", 1, true) == nil, answers)
  assert(answers:find("Blocked: the agent has called read 1 time, its budget", 1, true) ~= nil, answers)
  assert(answers:find("Blocked: the agent may not write " .. dir .. "/c.txt", 1, true) ~= nil, answers)
  local made, _ = Fs.read(dir .. "/c.txt")
  assert(made == nil)
  assert(#blocked == 2 and blocked[1]:find("^read: ") ~= nil and blocked[2]:find("^write: ") ~= nil, blocked[1])
  -- after sees each call that ran, with the paths it touches.
  local first = assert(seen[1])
  assert(#seen == 1 and first.name == "read" and first.caller == "model" and first.cwd == dir)
  assert(#first.paths == 1 and first.paths[1].path == dir .. "/a.txt" and first.paths[1].letters == "r")
  -- An error in on is kept, and the turn goes on.
  assert((s.on_failed or ""):find("a bug in the UI", 1, true) ~= nil, s.on_failed)
end

local function test_a_hook_that_raises_fails_closed()
  local dir = scratch()
  assert(Fs.write(dir .. "/a.txt", "fine"))
  local a = agent_fixture.api({ calling({ { name = "write", input = { path = "b.txt", content = "x" } },
    { name = "read", input = { path = "a.txt" } } }), DONE })
  local s = Agent.new({ sign = keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send, system = "" })
  s.before = function(call: Agent.Call): string?
    if call.name == "write" then error("no rule for write") end
    return nil
  end
  s.after = function(_: Agent.Call, _: Tools.Result): Tools.Result? error("broken") end
  assert(s:prompt("go"))
  local answers = said(a, 2)
  assert(answers:find("Blocked: the agent's before hook failed: ", 1, true) ~= nil, answers)
  local made, _ = Fs.read(dir .. "/b.txt")
  assert(answers:find("no rule for write", 1, true) ~= nil and made == nil, answers)
  assert(answers:find("The agent's after hook failed: ", 1, true) ~= nil, answers)
  -- A tool whose paths raise is blocked, and runs not.
  local ran = false
  local none: {string: Json.Value} = {}
  local odd: Tools.Tool = { name = "odd", snippet = "Odd", guidelines = {}, description = "Odd.",
    schema = { type = "object", properties = none },
    run = function(_: Tools.Object, _: Tools.Context): Tools.Result
      ran = true
      return { text = "ran", is_error = false }
    end,
    paths = function(_: Tools.Object, _: string): {Tools.Touch} error("no paths here") end }
  local b = agent_fixture.api({ calling({ { name = "odd", input = none } }), DONE })
  local t = Agent.new({ sign = keyed("k"), cwd = dir, base_url = "https://api.test", send = b.send, system = "",
    tools = { odd } })
  t.before = function(_: Agent.Call): string? return nil end
  assert(t:prompt("go"))
  local odd_answer = said(b, 2)
  assert(not ran and odd_answer:find("Blocked: the tool's paths failed: ", 1, true) ~= nil, odd_answer)
end

local function test_paths_are_made_plain_and_checked_as_granted()
  local read = assert(Tools.find(Tools.all(), "read"))
  local paths = assert(read.paths)
  local touched = assert(paths({ path = "../x/./y.txt" }, "/a/b")[1])
  assert(touched.path == "/a/x/y.txt" and touched.letters == "r", touched.path)
  assert(assert(paths({ path = "/../../etc/passwd" }, "/a")[1]).path == "/etc/passwd")
  local edit = assert(assert(Tools.find(Tools.all(), "edit")).paths)
  assert(assert(edit({ path = "f" }, "/a")[1]).letters == "rwc")
  local check = Check.paths({ grants = { { path = "/a/b", letters = "r" } } })
  local none: {string: Json.Value} = {}
  local function asked(path: string): string?
    return check({ name = "read", input = none, caller = "model", cwd = "/a/b", paths = paths({ path = path }, "/a/b"),
      stopped = function(): boolean return false end })
  end
  assert(asked("../b/in.txt") == nil)
  -- Profiles count, as the sandbox reads them.
  local system = Check.paths({ profiles = { "system" } })
  local function read_of(path: string): string?
    return system({ name = "read", input = none, caller = "model", cwd = "/", paths = paths({ path = path }, "/"),
      stopped = function(): boolean return false end })
  end
  assert(read_of("/usr/lib") == nil and read_of("/root/x") ~= nil, read_of("/usr/lib"))
  assert(asked("../../etc/passwd") == "the agent may not read /etc/passwd", asked("../../etc/passwd"))
end

local function test_ask_blocks_what_the_user_says_no_to()
  local dir = scratch()
  local asked: mut {string} = {}
  local deny = Check.ask(function(call: Agent.Call): boolean
    asked[#asked + 1] = call.name
    return false
  end)
  local none: {string: Json.Value} = {}
  local reason = deny({ name = "run", input = none, caller = "code", cwd = dir, paths = {},
    stopped = function(): boolean return false end })
  assert(reason == "the user said no to run" and asked[1] == "run", reason)
end
