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
  assert(#errs == 5, tostring(#errs))
  assert(errs[1] == "read a.tl, from line 3", errs[1])
  -- A failure shows in a fence named error; read's result, which is not run's or bash's, shows nothing.
  assert(table.concat(errs, "|", 2) == "```error|no match|for this|```", table.concat(errs, "|"))
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

--- What a snippet changed shows after what it printed: an edit as a diff, a write as its line count.
local function test_a_run_shows_the_files_its_snippet_changed()
  local _, errs = shown({ { kind = "result", name = "run", result = { text = "done", is_error = false,
    changes = { { path = "a.md", edits = { { old = "teh", new = "the" } } }, { path = "b.md", lines = 2 } } } } })
  local whole = table.concat(errs, "\n")
  assert(whole == "```output\ndone\n```\nedit a.md\n```diff\n@@\n-teh\n+the\n```\nwrite b.md (2 lines)", whole)
  -- A snippet that raised shows its error, then what it changed, and a count of the changes the answer had no room for.
  local _, failed = shown({ { kind = "result", name = "run", result = { text = "boom", is_error = true,
    changes = { { path = "c.md", lines = 1 }, { path = "", more = 3 } } } } })
  local told = table.concat(failed, "\n")
  assert(told == "```error\nboom\n```\nwrite c.md (1 line)\n... 3 more changes not shown", told)
end

local function test_call_shows_code_commands_and_edits()
  local function joined(name: string, input: {string: Json.Value}): string
    return table.concat(Show.call(name, input), "|")
  end
  assert(joined("run", { code = "local a = 1\nprint(a)\n" }) == "```teal|local a = 1|print(a)|```")
  -- A layout shows run's code as it lays it out, and one that returns nil shows it as written.
  local function upper(code: string): string? return code:upper() end
  local function none(_: string): string? return nil end
  assert(table.concat(Show.call("run", { code = "print(a)" }, upper), "|") == "```teal|PRINT(A)|```")
  assert(table.concat(Show.call("run", { code = "print(a)" }, none), "|") == "```teal|print(a)|```")
  assert(joined("bash", { command = "git status\ngit diff" }) == "```console|$ git status|git diff|```")
  assert(joined("write", { path = "a.md", content = "a\nb\n" }) == "write a.md (2 lines)")
  local edit = joined("edit", { path = "R.md", edits = {
    { oldText = "a\nb\nc", newText = "a\nB\nc" }, { oldText = "x", newText = "y\nz" } } })
  assert(edit == "edit R.md|```diff|@@| a|-b|+B| c|@@|-x|+y|+z|```", edit)
  -- The shapes the edit tool takes: a JSON string of the list, one object, and the fields at the top.
  local shapes: {{string: Json.Value}} = { { path = "R.md", edits = '[{"oldText":"a","newText":"b"}]' },
    { path = "R.md", edits = { oldText = "a", newText = "b" } }, { path = "R.md", oldText = "a", newText = "b" } }
  for _, shape in ipairs(shapes) do
    local one = joined("edit", shape)
    assert(one == "edit R.md|```diff|@@|-a|+b|```", one)
  end
  -- An offset with no integer shows no line, and raises nothing.
  assert(joined("read", { path = "a", offset = 1e300 }) == "read a")
  local long: mut {string} = {}
  for i = 1, 20 do long[#long + 1] = "print(" .. tostring(i) .. ")" end
  local cut = Show.call("run", { code = table.concat(long, "\n") })
  assert(#cut == 15 and cut[14] == "... 8 more lines" and cut[15] == "```", cut[14])
  -- A failure's first line is cut as the others are.
  local _, errs = shown({ { kind = "result", name = "run", result = { text = string.rep("x", 5000), is_error = true } } })
  local first = assert(errs[2])
  assert(#errs == 3 and #first == 120, tostring(#first))
  -- What run or bash said shows below the call, its first lines in a fence named output.
  local said: mut {string} = {}
  for i = 1, 9 do said[#said + 1] = tostring(i) end
  local _, outs = shown({ { kind = "result", name = "run", result = { text = table.concat(said, "\n"), is_error = false } } })
  assert(table.concat(outs, "|") == "```output|1|2|3|4|5|6|... 3 more lines|```", table.concat(outs, "|"))
end

local function test_a_fence_outlasts_the_backticks_it_holds()
  local _, errs = shown({ { kind = "result", name = "bash", result = { text = "```\nhi\n````", is_error = false } } })
  local joined = table.concat(errs, "|")
  assert(joined == "`````output|```|hi|````|`````", joined)
  -- What a program says reaches the terminal with no control bytes but tab.
  local _, plain = shown({ { kind = "result", name = "run",
    result = { text = "\27[31mred\27[0m\r\nover\27]52;c;aGk=\7\tend", is_error = false } } })
  joined = table.concat(plain, "|")
  assert(joined == "```output|[31mred[0m|over]52;c;aGk=\tend|```", joined)
  -- The model's words, and a path a call names, lose them too; an output of no lines shows no fence.
  local outs, errs2 = shown({ { kind = "text", text = "a\27[2Jb\nc" },
    { kind = "tool", name = "read", input = { path = "x\27[2J" } },
    { kind = "result", name = "run", result = { text = "", is_error = false } } })
  assert(#outs == 1 and outs[1] == "a[2Jb\nc", outs[1])
  assert(#errs2 == 1 and errs2[1] == "read x[2J", table.concat(errs2, "|"))
end

local function test_diff_keeps_one_line_of_context()
  local d = table.concat(Show.diff("1\n2\n3\n4\n5", "1\n2\nthree\n4\n5"), "|")
  assert(d == " 2|-3|+three| 4", d)
  assert(table.concat(Show.diff("", "new"), "|") == "+new")
  assert(table.concat(Show.diff("old\n", ""), "|") == "-old")
end
