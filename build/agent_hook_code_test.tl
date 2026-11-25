--- A snippet's calls of the agent (history, store, mcp) go through the agent's guard and amend, as `before` and `after`
--- see the model's calls: a blocked one raises in the snippet, and an amended answer is what it reads.
local Agent = require("cosmic.agent")
local Clock = require("cosmic.clock")
local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Policy = require("cosmic.agent.policy")
local Sessions = require("cosmic.agent.sessions")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")
local Worker = require("cosmic.agent.worker")

--- This program, which the worker runs, and a root of its own for it, which needs the nest promise.
Test.policy{ profiles = { "cosmic", "system" }, grants = { { path = "o/bin", letters = "rx" } }, env = { "PATH", "TMPDIR" },
  promises = { "nest" }, requires = { "nest" } }

local function test_a_snippets_calls_of_the_agent_are_guarded_and_amended()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local session = assert(Sessions.start(db, dir, "m", 0))
  local asked: mut {string} = {}
  local w = Worker.new()
  local context: Tools.Context = { cwd = dir, db = db, session = session, worker = w,
    policy = assert(Policy.of(dir, { mode = "write", network = false, grants = {} })),
    guard = function(name: string, input: Tools.Object): string?
      local text, _ = Json.encode(input)
      asked[#asked + 1] = name .. " " .. (text or "?")
      if name == "history" and input["query"] == "SELECT 1 AS n" then
        return "no history for snippets"
      end
      return nil
    end,
    amend = function(name: string, _: Tools.Object, result: Tools.Result): Tools.Result
      if name == "store.get" and result.text:find("42", 1, true) ~= nil then
        return { text = '"[redacted]"', is_error = false }
      end
      if result.is_error then
        return { text = "failed: " .. result.text:gsub("nosuch", "[table]"), is_error = true }
      end
      return result
    end }
  local code = "local Host = require(\"cosmic.agent.host\")\n" ..
    "local ran, why = pcall(Host.history, \"SELECT 1 AS n\")\n" ..
    "Host.store(\"k\", \"the secret is 42\")\n" ..
    "local _, odd = Host.call(\"edit\", { path = \"x\" })\n" ..
    "local _, bad = pcall(Host.history, \"SELECT * FROM nosuch\")\n" ..
    "return { ran = ran, why = tostring(why), loaded = Host.load(\"k\").value, odd = tostring(odd), bad = tostring(bad) }\n"
  local r = Tools.run("run", { code = code }, context)
  assert(not r.is_error, r.text)
  assert(r.text:find('"ran":false', 1, true) ~= nil and r.text:find("Blocked: no history for snippets", 1, true) ~= nil, r.text)
  assert(r.text:find('"loaded":"[redacted]"', 1, true) ~= nil, r.text)
  -- Each call is asked by its own name; one the agent serves not is refused before any hook is asked.
  local seen = table.concat(asked, " | ")
  assert(#asked == 4 and asked[1] == 'history {"query":"SELECT 1 AS n"}' and
      asked[2] == 'store.put {"key":"k","value":"the secret is 42"}' and asked[3] == 'history {"query":"SELECT * FROM nosuch"}' and
      asked[4] == 'store.get {"key":"k"}', seen)
  assert(r.text:find("serves no call", 1, true) ~= nil, r.text)
  -- A failed call goes through amend too.
  assert(r.text:find("failed: ", 1, true) ~= nil and r.text:find("nosuch", 1, true) == nil, r.text)
  Worker.close(w)
  local _, _ = db:close()
end

local function test_an_agents_before_sees_a_snippets_calls_as_code()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local code = "local _, why = pcall(require(\"cosmic.agent.host\").history, \"SELECT 1\")\nreturn tostring(why)"
  local a = agent_fixture.api({ { content = { { type = "tool_use", id = "t1", name = "run", input = { code = code } } },
    stop_reason = "tool_use" }, { content = { { type = "text", text = "done" } }, stop_reason = "end_turn" } })
  local w = Worker.new()
  local s = Agent.new({ sign = agent_fixture.keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send,
    system = "", worker = w, sandbox = { (assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))) } })
  local calls: mut {string} = {}
  s.before = function(call: Agent.Call): string?
    calls[#calls + 1] = call.name .. ":" .. call.caller
    if call.caller == "code" then return "snippets may not query" end
    return nil
  end
  local blocked: mut {string} = {}
  s.on = function(e: Agent.Event)
    if e.kind == "blocked" then
      blocked[#blocked + 1] = e.name .. " " .. e.caller .. ": " .. e.reason
    end
  end
  assert(s:prompt("go"))
  assert(#calls == 2 and calls[1] == "run:model" and calls[2] == "history:code", table.concat(calls, " "))
  assert(#blocked == 1 and blocked[1] == "history code: snippets may not query", blocked[1])
  local answer = agent_fixture.said(a, 2)
  assert(answer:find("Blocked: snippets may not query", 1, true) ~= nil, answer)
  s:close()
end

local function test_an_agents_after_sees_a_snippets_answers()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local code = "local Host = require(\"cosmic.agent.host\")\nHost.store(\"k\", \"token ghp_123\")\n" ..
    "return Host.load(\"k\").value"
  local a = agent_fixture.api({ { content = { { type = "tool_use", id = "t1", name = "run", input = { code = code } } },
    stop_reason = "tool_use" }, { content = { { type = "text", text = "done" } }, stop_reason = "end_turn" } })
  local w = Worker.new()
  local db = assert(Sessions.open(dir .. "/sessions.db"))
  local s = Agent.new({ sign = agent_fixture.keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send,
    system = "", worker = w, db = db, id = assert(Sessions.start(db, dir, "m", 0)),
    sandbox = { (assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))) } })
  local callers: mut {string} = {}
  s.after = function(call: Agent.Call, result: Tools.Result): Tools.Result?
    callers[#callers + 1] = call.name .. ":" .. call.caller
    if call.caller == "code" and result.text:find("ghp_", 1, true) ~= nil then
      return { text = '"[redacted]"', is_error = false }
    end
    return nil
  end
  assert(s:prompt("go"))
  local answer = agent_fixture.said(a, 2)
  -- The snippet read what after made of the store's answer, and returned it.
  assert(answer:find("[redacted]", 1, true) ~= nil, answer)
  assert(table.concat(callers, " ") == "store.put:code store.get:code run:model", table.concat(callers, " "))
  s:close()
  local _, _ = db:close()
end

--- A tool for code alone is not offered to the model, nor found when it calls it; a snippet calls it with Host.use,
--- under before as a call by code, by the tool's own name and with its paths.
local function test_a_tool_for_code_is_called_from_a_snippet_alone()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local none: {string: Json.Value} = {}
  local stamp: Tools.Tool = { name = "stamp", snippet = "Stamp a word", guidelines = {}, description = "Stamps a word.",
    schema = { type = "object", properties = none }, callers = "code",
    run = function(input: Tools.Object, _: Tools.Context): Tools.Result
      local word = input["word"]
      if not (word is string) then return { text = "no word", is_error = true } end
      return { text = "stamped " .. word, is_error = false }
    end,
    paths = function(_: Tools.Object, cwd: string): {Tools.Touch}
      return { { path = cwd .. "/stamps", action = "write" } }
    end }
  local code = "local Host = require(\"cosmic.agent.host\")\n" ..
    "local _, bad = pcall(Host.use, \"stamp\", {})\n" ..
    "local _, held = pcall(Host.use, \"stamp\", { word = \"no\" })\n" ..
    "local _, other = pcall(Host.use, \"read\", { path = \"x\" })\n" ..
    "return Host.use(\"stamp\", { word = \"hi\" }) .. \" / \" .. tostring(bad) .. \" / \" .. tostring(other) .. " ..
    "\" / \" .. tostring(held)\n"
  local a = agent_fixture.api({
    { content = { { type = "tool_use", id = "t1", name = "stamp", input = { word = "x" } } }, stop_reason = "tool_use" },
    { content = { { type = "tool_use", id = "t2", name = "run", input = { code = code } } }, stop_reason = "tool_use" },
    { content = { { type = "text", text = "done" } }, stop_reason = "end_turn" } })
  local w = Worker.new()
  local s = Agent.new({ sign = agent_fixture.keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send,
    system = "", worker = w, tools = { (assert(Tools.find(Tools.all(), "run"))), (assert(Tools.find(Tools.all(), "read"))), stamp },
    sandbox = { (assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))) } })
  local calls: mut {string} = {}
  s.before = function(call: Agent.Call): string?
    local touched = call.paths[1]
    calls[#calls + 1] = call.name .. ":" .. call.caller .. (if touched ~= nil then ":" .. touched.action else "" end)
    if call.input["word"] == "no" then return "no word no" end
    return nil
  end
  s.after = function(call: Agent.Call, result: Tools.Result): Tools.Result?
    if call.name == "stamp" and not result.is_error then
      return { text = result.text:upper(), is_error = false }
    end
    return nil
  end
  assert(s:prompt("go"))
  -- Not offered, and not found when called.
  local first = agent_fixture.said(a, 1)
  assert(first:find('"name":"stamp"', 1, true) == nil, first)
  local second = agent_fixture.said(a, 2)
  assert(second:find("Tool stamp not found", 1, true) ~= nil, second)
  local answer = agent_fixture.said(a, 3)
  -- after made the answer the snippet read; before blocked the call it refused.
  assert(answer:find("STAMPED HI", 1, true) ~= nil, answer)
  assert(answer:find("Blocked: no word no", 1, true) ~= nil, answer)
  assert(answer:find("host: use: no word", 1, true) ~= nil, answer)
  assert(answer:find("is one code may call; these are: stamp", 1, true) ~= nil, answer)
  assert(table.concat(calls, " ") == "run:model stamp:code:write stamp:code:write stamp:code:write",
    table.concat(calls, " "))
  s:close()
end

--- Calls of a tool for code from a snippet's tasks of their own each pass before and after, and each task reads its
--- own answer.
local function test_a_snippets_tasks_each_use_a_tool_for_code()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local none: {string: Json.Value} = {}
  local stamped: mut {string} = {}
  local stamp: Tools.Tool = { name = "stamp", snippet = "Stamp a word", guidelines = {}, description = "Stamps a word.",
    schema = { type = "object", properties = none }, callers = "code",
    run = function(input: Tools.Object, _: Tools.Context): Tools.Result
      -- The first call waits until the two others it lets through are answered, so it is the last answered, and
      -- each reply must find its own task, not the next one waiting. It waits for them, never for a time: calls
      -- served one at a time leave it alone here until the deadline, and the order below then fails.
      local word = tostring(input["word"])
      if word == "w1" then
        local deadline = Clock.monotonic_ns() + Clock.seconds(20)
        while #stamped < 2 and Clock.monotonic_ns() < deadline do
          local slept, _ = Poll.delay(Clock.ms(10))
          if not slept then break end
        end
      end
      stamped[#stamped + 1] = word
      return { text = "stamped " .. word, is_error = false }
    end }
  local code = "local Host = require(\"cosmic.agent.host\")\nlocal Poll = require(\"cosmic.poll\")\n" ..
    "local got: mut {integer: string} = {}\n" ..
    "Poll.run(function()\n  for i = 1, 4 do\n    local _ = Poll.spawn(function()\n" ..
    "      local ok, answer = pcall(Host.use, \"stamp\", { word = \"w\" .. tostring(i) })\n" ..
    "      got[i] = if ok then tostring(answer) else \"raised \" .. tostring(answer) end\n" ..
    "    end)\n  end\nend)\n" ..
    "return table.concat({ got[1] or \"-\", got[2] or \"-\", got[3] or \"-\", got[4] or \"-\" }, \",\")\n"
  local a = agent_fixture.api({
    { content = { { type = "tool_use", id = "t1", name = "run", input = { code = code } } }, stop_reason = "tool_use" },
    { content = { { type = "text", text = "done" } }, stop_reason = "end_turn" } })
  local w = Worker.new()
  local s = Agent.new({ sign = agent_fixture.keyed("k"), cwd = dir, base_url = "https://api.test", send = a.send,
    system = "", worker = w, tools = { (assert(Tools.find(Tools.all(), "run"))), stamp } })
  local before: mut {string} = {}
  local after: mut {string} = {}
  s.before = function(call: Agent.Call): string?
    if call.name == "stamp" then
      local word = tostring(call.input["word"])
      before[#before + 1] = word
      if call.input["word"] == "w3" then return "not w3" end
    end
    return nil
  end
  s.after = function(call: Agent.Call, result: Tools.Result): Tools.Result?
    if call.name ~= "stamp" then return nil end
    local word = tostring(call.input["word"])
    after[#after + 1] = word
    return { text = result.text:upper(), is_error = false }
  end
  assert(s:prompt("go"))
  local answer = agent_fixture.said(a, 2)
  assert(answer:find("STAMPED W1,STAMPED W2,raised host: use: Blocked: not w3,STAMPED W4", 1, true) ~= nil, answer)
  -- w1 was answered after w2 and w4, so its answer reached its own task out of order.
  assert(table.concat(stamped, " ") == "w2 w4 w1", table.concat(stamped, " "))
  table.sort(before)
  table.sort(after)
  assert(table.concat(before, " ") == "w1 w2 w3 w4", table.concat(before, " "))
  assert(table.concat(after, " ") == "w1 w2 w4", table.concat(after, " "))
  s:close()
end
