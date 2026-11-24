--- A snippet's calls of the agent (sql, store, mcp) go through the agent's guard and amend, as `before` and `after`
--- see the model's calls: a blocked one raises in the snippet, and an amended answer is what it reads.
local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
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
      if name == "sql" and input["query"] == "SELECT 1 AS n" then return "no sql for snippets" end
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
    "local ran, why = pcall(Host.sql, \"SELECT 1 AS n\")\n" ..
    "Host.store(\"k\", \"the secret is 42\")\n" ..
    "local _, odd = Host.call(\"edit\", { path = \"x\" })\n" ..
    "local _, bad = pcall(Host.sql, \"SELECT * FROM nosuch\")\n" ..
    "return { ran = ran, why = tostring(why), loaded = Host.load(\"k\").value, odd = tostring(odd), bad = tostring(bad) }\n"
  local r = Tools.run("run", { code = code }, context)
  assert(not r.is_error, r.text)
  assert(r.text:find('"ran":false', 1, true) ~= nil and r.text:find("Blocked: no sql for snippets", 1, true) ~= nil, r.text)
  assert(r.text:find('"loaded":"[redacted]"', 1, true) ~= nil, r.text)
  -- Each call is asked by its own name; one the agent serves not is refused before any hook is asked.
  local seen = table.concat(asked, " | ")
  assert(#asked == 4 and asked[1] == 'sql {"query":"SELECT 1 AS n"}' and
      asked[2] == 'store.put {"key":"k","value":"the secret is 42"}' and asked[3] == 'sql {"query":"SELECT * FROM nosuch"}' and
      asked[4] == 'store.get {"key":"k"}', seen)
  assert(r.text:find("serves no call", 1, true) ~= nil, r.text)
  -- A failed call goes through amend too.
  assert(r.text:find("failed: ", 1, true) ~= nil and r.text:find("nosuch", 1, true) == nil, r.text)
  Worker.close(w)
  local _, _ = db:close()
end

local function test_an_agents_before_sees_a_snippets_calls_as_code()
  local dir = assert(Fs.mkdtemp("agent-hook-"))
  local code = "local _, why = pcall(require(\"cosmic.agent.host\").sql, \"SELECT 1\")\nreturn tostring(why)"
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
  assert(#calls == 2 and calls[1] == "run:model" and calls[2] == "sql:code", table.concat(calls, " "))
  assert(#blocked == 1 and blocked[1] == "sql code: snippets may not query", blocked[1])
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
