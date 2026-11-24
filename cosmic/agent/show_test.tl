--- How the agent's events are shown: at a terminal, and as lines of JSON.

local Agent = require("cosmic.agent")
local Json = require("cosmic.json")
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
  assert(#errs == 3, tostring(#errs))
  assert(errs[1] == "read a.tl, from line 3", errs[1])
  assert(errs[2] == "edit failed: no match" and errs[3] == "    for this", errs[3])
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

local function test_text_sends_words_on_the_way_to_err()
  local outs, errs = shown({ { kind = "text", text = "looking", calls = true }, { kind = "text", text = "done" } })
  assert(#outs == 1 and outs[1] == "done", outs[1])
  assert(#errs == 1 and errs[1] == "looking", errs[1])
end

local function test_call_shows_code_commands_and_edits()
  local function joined(name: string, input: {string: Json.Value}): string
    return table.concat(Show.call(name, input), "|")
  end
  assert(joined("run", { code = "local a = 1\nprint(a)\n" }) == "run|    local a = 1|    print(a)")
  assert(joined("bash", { command = "git status\ngit diff" }) == "bash|    $ git status|    $ git diff")
  assert(joined("write", { path = "a.md", content = "a\nb\n" }) == "write a.md (2 lines)")
  assert(joined("sql", { query = "SELECT 1" }) == "sql SELECT 1")
  local edit = joined("edit", { path = "R.md", edits = {
    { oldText = "a\nb\nc", newText = "a\nB\nc" }, { oldText = "x", newText = "y\nz" } } })
  assert(edit == "edit R.md|    @@|     a|    -b|    +B|     c|    @@|    -x|    +y|    +z", edit)
  -- The shapes the edit tool takes: a JSON string of the list, one object, and the fields at the top.
  local shapes: {{string: Json.Value}} = { { path = "R.md", edits = '[{"oldText":"a","newText":"b"}]' },
    { path = "R.md", edits = { oldText = "a", newText = "b" } }, { path = "R.md", oldText = "a", newText = "b" } }
  for _, shape in ipairs(shapes) do
    local one = joined("edit", shape)
    assert(one == "edit R.md|    @@|    -a|    +b", one)
  end
  -- An offset with no integer shows no line, and raises nothing.
  assert(joined("read", { path = "a", offset = 1e300 }) == "read a")
  local long: mut {string} = {}
  for i = 1, 20 do long[#long + 1] = "print(" .. tostring(i) .. ")" end
  local cut = Show.call("run", { code = table.concat(long, "\n") })
  assert(#cut == 14 and cut[14] == "    ... 8 more lines", cut[14])
  -- A failure's first line is cut as the others are.
  local _, errs = shown({ { kind = "result", name = "run", result = { text = string.rep("x", 5000), is_error = true } } })
  local first = assert(errs[1])
  assert(#errs == 1 and #first == 120, tostring(#first))
end

local function test_diff_keeps_one_line_of_context()
  local d = table.concat(Show.diff("1\n2\n3\n4\n5", "1\n2\nthree\n4\n5"), "|")
  assert(d == " 2|-3|+three| 4", d)
  assert(table.concat(Show.diff("", "new"), "|") == "+new")
  assert(table.concat(Show.diff("old\n", ""), "|") == "-old")
end
