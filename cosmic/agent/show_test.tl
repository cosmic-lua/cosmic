--- How the agent's events are shown: at a terminal, and as lines of JSON.

local Agent = require("cosmic.agent")
local Show = require("cosmic.agent.show")
local Test = require("cosmic.test")

Test.policy{}

--- What [`Show.text`] writes for `events`: the lines to its out, and to its err.
local function shown(events: {Agent.Event}): {string}, {string}
  local outs: mut {string} = {}
  local errs: mut {string} = {}
  local text = Show.text(function(line: string) outs[#outs + 1] = line end,
    function(line: string) errs[#errs + 1] = line end)
  for _, e in ipairs(events) do text(e) end
  return outs, errs
end

local EVENTS <const>: {Agent.Event} = {
  { kind = "text", text = "hi" },
  { kind = "tool", name = "read", input = { path = "a.tl", offset = 3 } },
  { kind = "result", name = "read", result = { text = "fine", is_error = false } },
  { kind = "result", name = "edit", result = { text = "no match\nfor this", is_error = true } },
  { kind = "message", message = { role = "user", content = "go" } },
}

local function test_text_shows_words_and_each_call()
  local outs, errs = shown(EVENTS)
  assert(#outs == 1 and outs[1] == "hi", outs[1])
  assert(#errs == 2 and errs[1] == "read a.tl" and errs[2] == "edit failed: no match ...", errs[2])
  assert(Show.input({ command = "ls", path = "x" }) == "ls")
  assert(Show.input({ n = 1 }) == '{"n":1}', Show.input({ n = 1 }))
  assert(Show.brief(string.rep("x", 100)) == string.rep("x", 77) .. "...")
end

local function test_json_writes_a_line_an_event_but_text()
  local lines: mut {string} = {}
  local json = Show.json(function(line: string) lines[#lines + 1] = line end)
  for _, e in ipairs(EVENTS) do json(e) end
  assert(#lines == 4, tostring(#lines))
  assert(lines[1] == '{"input":{"offset":3,"path":"a.tl"},"name":"read","type":"tool"}', lines[1])
  assert(lines[2] == '{"is_error":false,"name":"read","type":"result"}', lines[2])
  assert(lines[3] == '{"is_error":true,"name":"edit","type":"result"}', lines[3])
  assert(lines[4] == '{"message":{"content":"go","role":"user"},"type":"message"}', lines[4])
end
