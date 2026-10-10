--- [`eval/summarize.tl`] over transcripts built here: what each line of
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
    -- A file's contents are not where the call acts.
    call("2", "Write", { file_path = arena .. "/f", content = "/etc/secret /elsewhere" }),
    call("3", "Grep", { pattern = "x", path = "/opt/y" }),
  })
  local report = Summarize.report(text, arena, repo)
  assert(report == lines({
    "turns=null tools=3 minutes=null cost=null (no result event: timed out?)",
    "failed_calls=0 docs_misses=0 first_green_test_call=null journal_writes=0",
    "sandbox-tmp: 1",
    "outside-arena: /a/y",
    "outside-arena: /b/x",
    "outside-arena: " .. arena .. "x/near",
  }), report)
end

--- The lines of the report after the two that count the run, for one call.
local function findings(name: string, input: {string: any}, in_arena?: string): string
  local text = call("1", name, input) .. "\n"
  local report = Summarize.report(text, in_arena or arena, repo)
  return (report:gsub("^[^\n]*\n[^\n]*\n", ""))
end

local function test_text_that_is_not_a_path_is_not_reported()
  local quiet: {string} = {
    "echo $(( (E-S)/1000000 ))",
    "echo $(( a / 1000 ))",
    "echo $((1 << 3)) $(( 4 / 2 ))",
    "awk -F/ '{ print $1 }' f",
    "cut -d '/' -f1 f",
    "tr '/' '_' < f",
    "IFS=/ read a b",
    "echo \"HOME=$HOME\"",
    "curl http://127.0.0.1:8080/x",
    "curl -s 'https://example.com/a/b' -o out",
    "sed -i 's/self:unlink(/self:detach(/g' f",
    "sed -n /x/p f",
    "printf 'GET /nope HTTP/1.1\\r\\n' | nc 127.0.0.1 80",
    "cosmic eval 'return \"America/New_York\"'",
    "x=America/New_York; echo $x",
    "grep '/run\\.' f",
    "grep -rn \"/run\\.\" .",
    "grep /foo/bar f",
    "grep -m 5 /foo/bar f",
    "grep -e /foo/bar f",
    "awk '{ print $1 \"/\" $2 }' f",
    "python3 -c \"import os; os.listdir('/root')\"",
    "perl -pi -e 's{/a}{/b}' f",
    "ls # see /root/x",
    "cat >> JOURNAL.md <<EOF\nnotes on /tmp/cosmic-cores-0 and /root/x\nEOF\necho done",
    "cat <<'EOF' > x\n/etc/claude-code\nEOF",
    "cat <<-EOF\n\t/root/y\n\tEOF\nls",
    "echo a > /dev/null 2>&1; ls /usr/bin /etc/hosts /proc/self",
    "cat ./a/b a/b",
    "cd /work/arena/project/sub; ls ../; cat ../project/x",
  }
  for _, command in ipairs(quiet) do
    local got = findings("Bash", { command = command })
    assert(got == "", command .. " -> " .. got)
  end
  assert(findings("Grep", { pattern = "/foo/bar", path = "src" }) == "")
  assert(findings("Glob", { pattern = "**/*.tl", path = "." }) == "")
  assert(findings("Read", { file_path = "notes.md" }) == "")
  assert(findings("Write", { file_path = arena .. "/project/x" }) == "")
end

local function test_a_path_that_leaves_the_arena_is_reported()
  local cases: {{string}} = {
    { "cat ~/x", "outside-arena: ~/x\n" },
    { "cat $HOME/x", "outside-arena: ~/x\n" },
    { "cat ${HOME}/x", "outside-arena: ~/x\n" },
    { "cat ~/.claude/x", "BREACH: ~/.claude/x\n" },
    { "cd ../../x", "outside-arena: /work/x\n" },
    { "cat ../../x/./y", "outside-arena: /work/x/y\n" },
    { "cat a/../../../x", "outside-arena: /work/x\n" },
    { "cat /home/user/cosmic/AGENTS.md", "BREACH: /home/user/cosmic/AGENTS.md\n" },
    { "cat /srv/CLAUDE.md", "BREACH: /srv/CLAUDE.md\n" },
    { "cat " .. repo .. "/README.md",
      "BREACH: " .. repo .. "/README.md\nCONTAMINATION: a tool call named " .. repo .. "\n" },
    { "ls /mnt/skills/x", "BREACH: /mnt/skills/x\n" },
    { "cat /etc/claude-code/managed-settings.json",
      "BREACH: /etc/claude-code/managed-settings.json\n" },
    { "ls /tmp/cosmic-evals/other/project", "BREACH: /tmp/cosmic-evals/other/project\n" },
    { "> /root/x", "BREACH: /root/x\n" },
    { "echo hi >/root/x", "BREACH: /root/x\n" },
    { "echo hi >> /root/x 2>/root/y", "BREACH: /root/x\nBREACH: /root/y\n" },
    { "FOO=/root/x env", "BREACH: /root/x\n" },
    { "tool --out=/root/x", "BREACH: /root/x\n" },
    { "sed -n 's/a/b/p' /root/f", "BREACH: /root/f\n" },
    { "grep -m 5 pat /root/f", "BREACH: /root/f\n" },
    { "grep -e pat /root/f", "BREACH: /root/f\n" },
    { "sh -c 'cat /root/x'", "BREACH: /root/x\n" },
    { "echo $(cat /root/x)", "BREACH: /root/x\n" },
    { "ls /tmp/a /tmp/b /tmp//a", "sandbox-tmp: 2\n" },
    -- A shift is no here-document, and a redirect needs no space.
    { "echo $((1 << 3))\ncat /root/x", "BREACH: /root/x\n" },
    { "x=$(( 1 << 3 ))\ncat /root/x", "BREACH: /root/x\n" },
    { "echo $((1 << n))\ncat /root/x", "BREACH: /root/x\n" },
    { "echo $((x<<y))\ncat /root/x", "BREACH: /root/x\n" },
    { "((x = y << z))\ncat /root/x", "BREACH: /root/x\n" },
    { "timeout 5 sh -c 'cat /root/x'", "BREACH: /root/x\n" },
    { "env F=1 sh -c 'cat /root/x'", "BREACH: /root/x\n" },
    { "nohup sh -c 'cat /root/x'", "BREACH: /root/x\n" },
    { "ls | xargs sh -c 'cat /root/x'", "BREACH: /root/x\n" },
    { "timeout -k 1 5 env -i eval cat /root/x", "BREACH: /root/x\n" },
    { "echo hi>/root/x", "BREACH: /root/x\n" },
    { "cat</root/x", "BREACH: /root/x\n" },
    { "cmd 2>&1>/root/x", "BREACH: /root/x\n" },
    { "ls /", "outside-arena: /\n" },
    { "cd /", "outside-arena: /\n" },
    { "find / -name x", "outside-arena: /\n" },
    { "grep -r foo /", "outside-arena: /\n" },
    -- A file option makes the next word a path, not a script.
    { "sed -f /root/s f", "BREACH: /root/s\n" },
    { "awk -f /root/s.awk f", "BREACH: /root/s.awk\n" },
    { "grep -f /root/pats f", "BREACH: /root/pats\n" },
    { "rg --files /root", "BREACH: /root\n" },
    { "cat \"${HOME}/x\"", "outside-arena: ~/x\n" },
    { "cat \"/root/my dir/x\"", "BREACH: /root/my dir/x\n" },
    { "cat \"~/my dir\"", "outside-arena: ~/my dir\n" },
    { "tar -T/root/x", "BREACH: /root/x\n" },
    { "cc -I/root/inc", "BREACH: /root/inc\n" },
    { "git -C/root log", "BREACH: /root\n" },
    { "tool @/root/x", "BREACH: /root/x\n" },
    { "cat ~root/x", "outside-arena: ~root/x\n" },
    { "cat $PWD/../../x", "outside-arena: /work/x\n" },
    { "cat ${PWD}/../../x", "outside-arena: /work/x\n" },
    { "cat $'/root/x'", "BREACH: /root/x\n" },
    { "ls /proc/1/root/etc", "outside-arena: /proc/1/root/etc\n" },
    { "ls /proc/self/cwd", "outside-arena: /proc/self/cwd\n" },
    { "eval \"cat /root/x\"", "BREACH: /root/x\n" },
    { "ls /srv//x/../y", "outside-arena: /srv/y\n" },
  }
  for _, case in ipairs(cases) do
    local got = findings("Bash", { command = case[1] })
    assert(got == case[2], case[1] .. " -> " .. got)
  end
  assert(findings("Read", { file_path = "/mnt/skills/x" }) == "BREACH: /mnt/skills/x\n")
  assert(findings("Edit", { file_path = "../../x" }) == "outside-arena: /work/x\n")
  assert(findings("Glob", { pattern = "/root/**" }) == "BREACH: /root/**\n")
  assert(findings("Glob", { pattern = "~/x/*" }) == "outside-arena: ~/x/*\n")
  assert(findings("Glob", { pattern = "../../*.tl" }) == "outside-arena: /work/*.tl\n")
  assert(findings("Grep", { pattern = "x", glob = "../../*.tl" }) == "outside-arena: /work/*.tl\n")
  assert(findings("Grep", { pattern = "x", glob = "*.tl" }) == "")
  assert(findings("Glob", { pattern = "*.tl", path = "/srv/d" }) == "outside-arena: /srv/d\n")
  assert(findings("Grep", { pattern = "x", path = "/etc/claude-code" }) ==
      "BREACH: /etc/claude-code\n")
  -- From a deep arena, `..` reaches the other arenas.
  assert(findings("Bash", { command = "cd ../../.." }, "/tmp/cosmic-evals/m/claude/run-001") ==
      "BREACH: /tmp/cosmic-evals/m\n")
end

local function test_paths_resolves_what_a_call_names()
  local project <const> = arena .. "/project"
  local found = Summarize.paths("Bash", { command = "cp a ../b; cat '/x/y z' /p" }, project)
  assert(table.concat(found, " ") == arena .. "/b /x/y z /p", table.concat(found, " "))
  assert(#Summarize.paths("Bash", { command = 3 }, project) == 0)
end

local function test_only_a_cosmic_test_run_is_green()
  local function green(command: string, output: string): string
    local report = Summarize.report(
      call("1", "Bash", { command = command }) .. "\n" .. answer("1", output) .. "\n", arena, repo)
    return report:match("first_green_test_call=(%w+)")
  end
  local pass <const> = "build: ok\ntest: PASS (3 ran)"
  assert(green("cosmic test", pass) == "1")
  assert(green("cd p && timeout 30 bin/cosmic test 2>&1 | tail -5", pass) == "1")
  -- Documentation that prints the line is no run.
  assert(green("cosmic docs doc.guides.project", "see\ntest: PASS (n ran)") == "null")
  assert(green("cosmic help test", pass) == "null")
  assert(green("echo 'cosmic test'", pass) == "null")
  -- Nor is a result that mentions it in a line of its own prose.
  assert(green("cosmic test", "the last test: PASS was earlier\ntest: FAIL") == "null")
  assert(green("cosmic test", "test: FAIL") == "null")
  assert(green("(cd p && cosmic test)", pass) == "1")
  assert(green("out=$(cosmic test)", pass) == "1")
  assert(green("sh -c 'cd p && cosmic test'", pass) == "1")
  assert(green("cosmic test | grep -v x | tail -3", pass) == "1")
  -- A command that prints the line itself, or a call that failed, is no run.
  assert(green("cosmic test && echo PASS", pass) == "1")
  assert(green("cosmic test; cat <<EOF\ntest: PASS\nEOF", "test: PASS") == "null")
  assert(green("cosmic test; python3 -c 'print(\"test: PASS\")'", "test: PASS") == "null")
  assert(green("cosmic test; echo 'test: PASS'", "test: PASS") == "null")
  assert(green("cosmic test || echo test: PASS", "test: PASS") == "null")
  assert(green("cosmic test; printf 'test: PASS\\n'", "test: PASS") == "null")
  local failed = Summarize.report(call("1", "Bash", { command = "cosmic test" }) .. "\n" ..
      answer("1", pass, true) .. "\n", arena, repo)
  assert(failed:find("first_green_test_call=null", 1, true), failed)
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
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1",' ..
      '"content":"test: PASS \\ud83d","is_error":false}]}}',
  })
  local report = Summarize.report(text, arena, repo)
  assert(report:find("failed_calls=0 docs_misses=0 first_green_test_call=1", 1, true), report)
end

local function test_a_line_python_reads_is_read()
  local deep = string.rep("[", 70) .. string.rep("]", 70)
  local text = table.concat({
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"1","name":"Bash",' ..
      '"input":{"command":"ls /deep","x":' .. deep .. '}}]}}',
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
