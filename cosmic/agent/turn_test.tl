--- The agent's turn as it runs a tool: each output kept before it is shown, the note that names a cut output's
--- whole, and the user's stop and steer. The tool is the tests' own ([`agent_fixture.SAY`]).

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{ env = { "TMPDIR" } }

local said = agent_fixture.said
local text_reply = agent_fixture.text_reply
local say_call = agent_fixture.say_call
local function kept(replies: {Json.Value}, messages?: {Json.Value}, model?: string): Agent.Session, Api,
                    Sqlite.Handle
  local k = agent_fixture.kept(replies, messages, model)
  return k.session, k.api, k.db
end
local type Api = agent_fixture.Api

local function test_each_output_is_kept_before_it_is_shown()
  local s, _, db = kept({ { content = { say_call("t1", "one") }, stop_reason = "tool_use" }, text_reply("ok") })
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
  s, _, db = kept({ { content = { say_call("t2", string.rep("line\n", 3000)) }, stop_reason = "tool_use" }, text_reply("ok") })
  assert(s:prompt("go"))
  local answer = assert(Sessions.answer(db, assert(s.id), "t2"))
  assert(#answer.text < 11000, answer.text:sub(-100))
  local whole = assert(db:rows("SELECT length(text), call FROM outputs WHERE call = 't2'"))
  assert(assert(whole[1]):integer(1) > 13000)
  -- The note names the Host.output call that reads it in a snippet of run.
  local id = assert(assert(db:rows("SELECT id FROM outputs WHERE call = 't2'"))[1]):integer(1)
  -- It comes first, where a model that reads only the top sees it.
  assert(answer.text:find("[The whole output is kept as output " .. tostring(id) .. ": read it in run with Host.output(" ..
      tostring(id) .. ").]\n", 1, true) == 1, answer.text:sub(1, 100))
  -- With no run tool, nothing reads it, so there is no note.
  s, _, db = kept({ { content = { say_call("t3", string.rep("line\n", 3000)) }, stop_reason = "tool_use" }, text_reply("ok") })
  s.tools = { agent_fixture.SAY }
  assert(s:prompt("go"))
  local bare = assert(Sessions.answer(db, assert(s.id), "t3"))
  assert(bare.text:find("kept as output", 1, true) == nil, bare.text:sub(-100))
end

local function test_the_user_stops_and_steers_a_turn()
  local two: Json.Value = { content = { say_call("t1", "one"), say_call("t2", "two") },
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
