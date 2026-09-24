--- `eval/summarize.tl` over transcripts built here: what each line of
--- its report counts, and what it skips.
local Json = require("cosmic.json")
local Summarize = require("eval.summarize")

local arena <const> = "/work/arena"
local repo <const> = "/src/cosmic"

local function call(id: string, name: string, input: {string: any}): string
  return (assert(Json.encode({ type = "assistant", message = { content = {
    { type = "text", text = "thinking" },
    { type = "tool_use", id = id, name = name, input = input },
  } } })))
end

local function answer(id: string, content: any, is_error?: boolean): string
  return (assert(Json.encode({ type = "user", message = { content = {
    { type = "tool_result", tool_use_id = id, content = content,
      is_error = is_error or false },
  } } })))
end

local function lines(list: {string}): string
  return table.concat(list, "\n") .. "\n"
end

local function test_the_first_lines_count_the_run()
  local text = lines({
    call("1", "Bash", { command = "cosmic docs Fs.nope" }),
    answer("1", "docs: FAIL\nNo exact symbol match", true),
    call("2", "Bash", { command = "cosmic test" }),
    answer("2", { { type = "text", text = "build: ok" }, { type = "text", text = "test: PASS" } }),
    call("3", "Bash", { command = "cosmic test" }),
    answer("3", "test: PASS"),
    (assert(Json.encode({ type = "result", num_turns = 7, duration_ms = 90000,
      total_cost_usd = 0.125 }))),
  })
  assert(Summarize.report(text, arena, repo) == lines({
    "turns=7 tools=3 minutes=1.5 cost=$0.12",
    "failed_calls=1 docs_misses=2 first_green_test_call=2 journal_writes=0",
  }))
end

local function test_a_run_without_a_result_says_it_may_have_timed_out()
  local text = lines({ call("1", "Bash", { command = "true" }), "not json", "3", "" })
  assert(Summarize.report(text, arena, repo) == lines({
    "turns=null tools=1 minutes=null cost=null (no result event: timed out?)",
    "failed_calls=0 docs_misses=0 first_green_test_call=null journal_writes=0",
  }))
end

local function test_a_journal_write_is_a_write_an_edit_or_a_shell_redirection()
  local text = lines({
    call("1", "Write", { file_path = arena .. "/project/JOURNAL.md", content = "x" }),
    call("2", "Edit", { file_path = "JOURNAL.md" }),
    call("3", "Bash", { command = "echo x >> JOURNAL.md" }),
    call("4", "Bash", { command = "echo x | tee -a notes/JOURNAL.md" }),
    call("5", "Bash", { command = "cat JOURNAL.md" }),
    call("6", "Read", { file_path = "JOURNAL.md" }),
  })
  local report = Summarize.report(text, arena, repo)
  assert(report:find("journal_writes=4", 1, true), report)
end

local function test_paths_outside_the_arena_are_listed_once_and_sorted()
  local text = lines({
    call("1", "Bash", { command = "ls /b/x /a/y /b/x " .. arena .. " " .. arena ..
      "/project/ok " .. arena .. "x/near /usr/bin/env /usr /tmp//w" }),
    -- Relative paths, and those under a variable or home, are not absolute.
    call("2", "Bash", { command = "cat ./a/b a/b $HOME/c ~/d <x>/e" }),
    -- A file's contents are not where the call acts.
    call("3", "Write", { file_path = arena .. "/f", content = "/etc/secret /elsewhere" }),
    call("4", "Grep", { pattern = "x", path = "/opt/y" }),
  })
  local report = Summarize.report(text, arena, repo)
  local outside: {string} = {}
  for path in report:gmatch("outside%-arena: ([^\n]+)") do
    outside[#outside + 1] = path
  end
  assert(table.concat(outside, " ") == "/a/y /b/x /tmp /w " .. arena .. "x/near",
    table.concat(outside, " "))
end

local function test_paths_follows_the_characters_a_path_is_made_of()
  local found = Summarize.paths("a=/x/y.z;b=/p@q/r+s-t:/u")
  assert(table.concat(found, " ") == "/x/y.z /p@q/r+s-t /u", table.concat(found, " "))
  assert(#Summarize.paths("no paths / here, x/y") == 0)
end

local function test_a_mention_of_the_repository_or_skills_is_contamination()
  local text = lines({
    call("1", "Read", { file_path = repo .. "/README.md" }),
    call("2", "Bash", { command = "ls ~/.claude/skills" }),
    call("3", "Write", { file_path = "x", content = "see ~/.claude/plugins" }),
  })
  local report = Summarize.report(text, arena, repo)
  local marks: {string} = {}
  for mark in report:gmatch("CONTAMINATION: a tool call named ([^\n]+)") do
    marks[#marks + 1] = mark
  end
  assert(table.concat(marks, " ") == ".claude/plugins .claude/skills " .. repo,
    table.concat(marks, " "))
end

local function test_a_lone_surrogate_does_not_lose_the_line()
  -- Claude Code cuts a tool's output in the middle of an emoji.
  local text = lines({
    call("1", "Bash", { command = "cosmic test" }),
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1",'
      .. '"content":"test: PASS \\ud83d","is_error":true}]}}',
  })
  local report = Summarize.report(text, arena, repo)
  assert(report:find("failed_calls=1 docs_misses=0 first_green_test_call=1", 1, true), report)
end

local function test_punctuation_past_ascii_does_not_hide_a_path()
  local found = Summarize.paths("cat \u{201c}/root/secret\u{201d} \u{2026}/x /a\u{a0}/b \u{2192}/y /\u{e9}t\u{e9}")
  assert(table.concat(found, " ") == "/root/secret /x /a /b /y /\u{e9}t\u{e9}", table.concat(found, " "))
end

local function test_a_line_python_reads_is_read()
  local deep = string.rep("[", 70) .. string.rep("]", 70)
  local text = table.concat({
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Bash",'
      .. '"input":{"command":"ls /deep","x":' .. deep .. '}}]}}',
    call("2", "Bash", { command = "ls /cr" }),
  }, "\r") .. "\r"
  local report = Summarize.report(text, arena, repo)
  assert(report:find("tools=2", 1, true), report)
  assert(report:find("outside-arena: /cr", 1, true), report)
end

local function test_is_error_counts_as_python_would()
  local text = lines({
    call("1", "Bash", { command = "a" }), answer("1", "x", false),
    call("2", "Bash", { command = "b" }),
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"2","content":"x","is_error":0}]}}',
    call("3", "Bash", { command = "c" }),
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"3","content":"x","is_error":"yes"}]}}',
  })
  local report = Summarize.report(text, arena, repo)
  assert(report:find("failed_calls=1 ", 1, true), report)
end

local function test_a_result_without_turns_says_null()
  local report = Summarize.report('{"type":"result"}\n', arena, repo)
  assert(report:find("^turns=null tools=0 minutes=0.0 cost=%$0.00\n"), report)
end
