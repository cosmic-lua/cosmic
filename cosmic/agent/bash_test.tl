--- The bash tool, unsandboxed, as the agent loop runs it: its output,
--- status and time limit, and each output kept before it is shown. It runs
--- the host's bash, found on PATH, and what each command names.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Tools = require("cosmic.agent.tools")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

-- The host programs the tests start, each where hosts keep it: named,
-- not the whole system, so the key holds them alone. /bin/sh is the
-- shell the bash tool falls back to on a host with no bash (Alpine's
-- busybox, which its sleep, seq, head and tr link to as well).
Test.policy{
  grants = {
    { path = "/bin/bash", letters = "r" }, { path = "/usr/bin/bash", letters = "r" },
    { path = "/bin/sh", letters = "r" },
    { path = "/bin/seq", letters = "r" }, { path = "/usr/bin/seq", letters = "r" },
    { path = "/bin/head", letters = "r" }, { path = "/usr/bin/head", letters = "r" },
    { path = "/bin/tr", letters = "r" }, { path = "/usr/bin/tr", letters = "r" },
    { path = "/bin/sleep", letters = "r" }, { path = "/usr/bin/sleep", letters = "r" },
  },
  env = { "PATH", "TMPDIR" },
}

local NONE <const>: {string: Json.Value} = {}
local scratch = agent_fixture.scratch
local run = agent_fixture.run
local said = agent_fixture.said
local text_reply = agent_fixture.text_reply
local bash_call = agent_fixture.bash_call
local function kept(replies: {Json.Value}, messages?: {Json.Value}, model?: string): Agent.Session, Api,
                    Sqlite.Handle
  local k = agent_fixture.kept(replies, messages, model)
  return k.session, k.api, k.db
end
local type Api = agent_fixture.Api

local function test_bash_runs_in_the_directory_and_says_its_status()
  local dir = scratch()
  local r = run("bash", { command = "pwd; echo out; echo err >&2" }, dir)
  assert(not r.is_error and r.text == dir .. "\nout\nerr", "[" .. r.text .. "]")
  local failed = run("bash", { command = "exit 3" }, dir)
  assert(failed.is_error and failed.text == "(no output)\n\nCommand exited with code 3", failed.text)
  local slow = run("bash", { command = "sleep 5", timeout = 1 }, dir)
  assert(slow.is_error and slow.text:find("timed out after 1 second") ~= nil, slow.text)
  local long = run("bash", { command = "seq 1 3000" }, dir)
  assert(long.text:find("^1001\n") ~= nil and (long.raw or ""):find("^1\n2\n") ~= nil, long.text:sub(1, 20))
  local one = run("bash", { command = "head -c 60000 /dev/zero | tr '\\0' y" }, dir)
  assert(one.text:find("^" .. string.rep("y", 100)) ~= nil, one.text:sub(1, 40))
  assert(run("bash", NONE, dir).is_error)
  local nope = run("nope", NONE, dir).text
  assert(nope:find("^Tool nope not found: the tools are read, bash, run") ~= nil, nope)
end

local function test_each_output_is_kept_before_it_is_shown()
  local s, _, db = kept({ { content = { bash_call("t1", "echo one") }, stop_reason = "tool_use" }, text_reply("ok") })
  local found, kept_messages = 0, 0
  s.on = function(e: Agent.Event)
    if e.kind == "result" then
      local answer = assert(Sessions.answer(db, assert(s.id), "t1"))
      assert(answer.text == "one", answer.text)
      found = found + 1
    elseif e.kind == "message" then
      local loaded = assert(Sessions.load(db, assert(s.id)))
      assert(#loaded.messages == #s.messages)
      kept_messages = kept_messages + 1
    end
  end
  assert(s:prompt("go"))
  assert(found == 1 and kept_messages == 4, tostring(kept_messages))
  -- A whole output too long to show is kept, with what the model read.
  local _: Api
  s, _, db = kept({ { content = { bash_call("t2", "seq 3000") }, stop_reason = "tool_use" }, text_reply("ok") })
  assert(s:prompt("go"))
  local answer = assert(Sessions.answer(db, assert(s.id), "t2"))
  assert(#answer.text < 20000, answer.text:sub(-100))
  local whole = assert(db:rows("SELECT length(text), call FROM outputs WHERE call = 't2'"))
  assert(assert(whole[1]):integer(1) > 13000)
  -- The note names the Host.output call that reads it in a snippet of run.
  local id = assert(assert(db:rows("SELECT id FROM outputs WHERE call = 't2'"))[1]):integer(1)
  assert(answer.text:find("kept as output " .. tostring(id) .. ": read it in run with Host.output(" .. tostring(id) ..
      ").]", 1, true) ~= nil, answer.text:sub(-100))
  -- With no run tool, nothing reads it, so there is no note.
  s, _, db = kept({ { content = { bash_call("t3", "seq 3000") }, stop_reason = "tool_use" }, text_reply("ok") })
  s.tools = Tools.without(s.tools, { "run" })
  assert(s:prompt("go"))
  local bare = assert(Sessions.answer(db, assert(s.id), "t3"))
  assert(bare.text:find("kept as output", 1, true) == nil, bare.text:sub(-100))
end

local function test_the_user_stops_and_steers_a_turn()
  local two: Json.Value = { content = { bash_call("t1", "echo one"), bash_call("t2", "echo two") },
    stop_reason = "tool_use" }
  local s, a, db = kept({ two, text_reply("never") })
  local seen = agent_fixture.events()
  local ran = 0
  local typed: mut {string} = {}
  s.on = function(e: Agent.Event)
    seen.on(e)
    if e.kind == "result" then ran = ran + 1 end
  end
  s.stopping = function(): boolean return ran > 0 end
  local ok, why = s:prompt("go")
  assert(not ok and why == "stopped by the user" and ran == 1 and #a.sent == 1, why)
  local third = s.messages[3]
  assert(third ~= nil)
  local answers = assert(Json.encode(third))
  assert(answers:find("Stopped: the user", 1, true) ~= nil, answers)
  assert(s.stopped and not s:unfinished() and assert(Sessions.load(db, assert(s.id))).ended)
  -- Steering goes to the model after the call running, and skips the rest.
  s, a = kept({ two, text_reply("steered"), text_reply("and more") })
  ran = 0
  local function steered(t: Agent.Session)
    t.on = function(e: Agent.Event)
      seen.on(e)
      if e.kind == "result" then
        ran = ran + 1
        typed[#typed + 1] = "do this instead"
      end
    end
    t.steering = function(): {string}
      local out: mut {string} = {}
      for _, x in ipairs(typed) do out[#out + 1] = x end
      typed = {}
      return out
    end
  end
  steered(s)
  assert(s:prompt("go"))
  local second = said(a, 2)
  assert(ran == 1 and second:find("Skipped: the user sent", 1, true) ~= nil, second)
  assert(second:find('{"text":"do this instead","type":"text"}', 1, true) ~= nil, second)
  assert(#a.sent == 2 and seen.texts[#seen.texts] == "steered")
  -- What comes while the model writes its last words is the next of the turn.
  s, a = kept({ text_reply("first"), text_reply("second") })
  typed = { "one more thing" }
  steered(s)
  assert(s:prompt("go"))
  assert(#a.sent == 2 and said(a, 2):find('"one more thing"', 1, true) ~= nil, said(a, 2))
end
