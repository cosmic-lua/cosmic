local Failures = require("cosmic_ci.failures")
local Fs = require("cosmic.fs")
local Seams = require("cosmic_ci.seams")

local function test_pick_keeps_the_lines_that_say_what_failed_in_order_each_once()
  local text = table.concat({
    "build: 1388 modules (1 compiled) in 4249 ms",
    "test: FAIL  cosmic.x_test test_one: cosmic.x_test:2: one is not two",
    "  rerun: cosmic test cosmic/x_test.tl:test_one",
    "test: PASS  cosmic.x_test test_two",
    "fix: FAIL  ci/x.tl: the plurals check: \"2 minutes\" is a literal count",
    "core/profile.c:154:7: error: use of undeclared identifier 'O_NOFOLLOW'",
    "cosmic/y.tl:2:19: `x` is `integer`, where `string` is wanted (not_assignable): pass a string",
    "test: FAIL  cosmic.x_test test_one: cosmic.x_test:2: one is not two",
    "core/startup.c:entry_refusal: a C function no test enters",
    "core/x.c:1:10: fatal error: 'y.h' file not found",
    "ld.lld: error: undefined symbol: z",
    "fatal: not a git repository",
    "test: 1 of 2 tests failed, 0 infrastructure errors, 14758 ms",
  }, "\n")
  local picked = Failures.pick(text)
  assert(#picked == 8, table.concat(picked, "\n"))
  assert(picked[1] == "test: FAIL  cosmic.x_test test_one: cosmic.x_test:2: one is not two")
  assert(assert(picked[2]):find("^fix: FAIL  ci/x.tl") ~= nil)
  assert(assert(picked[3]):find("O_NOFOLLOW", 1, true) ~= nil)
  assert(assert(picked[4]):find("(not_assignable)", 1, true) ~= nil)
  assert(picked[5] == "core/startup.c:entry_refusal: a C function no test enters")
  assert(picked[6] == "core/x.c:1:10: fatal error: 'y.h' file not found")
  assert(picked[7] == "ld.lld: error: undefined symbol: z" and picked[8] == "fatal: not a git repository")
end

local function test_pick_keeps_the_first_lines_and_cuts_a_long_one()
  local lines: mut {string} = {}
  for n = 1, 60 do lines[#lines + 1] = "test: FAIL  case " .. tostring(n) end
  lines[1] = "test: FAIL  " .. string.rep("x", 1000)
  local picked = Failures.pick(table.concat(lines, "\n"))
  assert(#picked == 40)
  assert(#assert(picked[1]) < 450 and assert(picked[1]):find("%.%.%.$") ~= nil)
  assert(picked[40] == "test: FAIL  case 40")
end

--- A long line is cut before a character, never inside one.
local function test_pick_cuts_a_long_line_between_characters()
  local picked = Failures.pick("test: FAIL  a" .. string.rep("\u{e9}", 300) .. "\n")
  local line = assert(picked[1])
  assert(line:find("%.%.%.$") ~= nil and utf8.len(line) ~= nil and #line == 402, tostring(#line))
end

local function test_pick_finds_nothing_in_a_passing_log()
  assert(#Failures.pick("build: 3 modules\ntest: 2 tests passed\n") == 0)
end

--- Runs `body` with the seams of a job: RUNNER_TEMP at `tmp`, a summary
--- file there, and stdout kept; returns what stdout got.
local function in_a_job(tmp: string, body: function(), actions?: boolean): string
  local seams = Seams.calls()
  local get, put = seams.env_get, seams.fs_put
  local said: mut {string} = {}
  seams.env_get = function(name: string): string?
    if name == "RUNNER_TEMP" then return tmp end
    if name == "GITHUB_STEP_SUMMARY" then return tmp .. "/summary.md" end
    if name == "GITHUB_ACTIONS" then return if actions == false then "" else "true" end end
    return get(name)
  end
  seams.fs_put = function(fd: integer, bytes: string): boolean, string
    if fd == Fs.stdout then
      said[#said + 1] = bytes
      return true, ""
    end
    return put(fd, bytes)
  end
  local ran, raised = pcall(body)
  seams.env_get, seams.fs_put = get, put
  assert(ran, tostring(raised))
  return table.concat(said)
end

local function test_keep_annotates_summarizes_and_keeps_the_lines_for_the_failures_step(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic-ci"))
  local out = in_a_job(tmp, function()
    Failures.keep("fixture: format, check", "build: 3 modules\nfix: FAIL  a 100% ```wrong``` line\n")
    Failures.keep("ci check", "nothing to see\n")
  end)
  assert(out == "::error title=fixture%3A format%2C check::fix: FAIL  a 100%25 ```wrong``` line\n", out)
  local summary = assert(Fs.read(tmp .. "/summary.md"))
  assert(summary:find("**fixture: format, check failed:**\n\n````\nfix: FAIL  a 100% ```wrong``` line\n````\n",
    1, true) ~= nil, summary)
  local printed = in_a_job(tmp, function()
    assert(Failures.command({}) == 0)
  end)
  assert(printed == "failures: what the failed steps said of it, again:\n\n" ..
      "fixture: format, check failed; what it said of that:\nfix: FAIL  a 100% ```wrong``` line\n", printed)
end

--- Outside a job of GitHub Actions (ci/run-local), the lines are kept for
--- the failures step, with no annotation or summary.
local function test_keep_outside_actions_only_keeps_the_lines(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic-ci"))
  local out = in_a_job(tmp, function()
    Failures.keep("ci check", "error: it broke\n")
  end, false)
  assert(out == "", out)
  assert(assert(Fs.status(tmp .. "/summary.md")).exists == false)
  local printed = in_a_job(tmp, function()
    assert(Failures.command({}) == 0)
  end)
  assert(printed:find("error: it broke", 1, true) ~= nil, printed)
end

local function test_the_failures_step_says_so_when_no_line_was_kept(tmp: string)
  local printed = in_a_job(tmp, function()
    assert(Failures.command({}) == 0)
  end)
  assert(printed:find("^failures: no step kept a line") ~= nil, printed)
end

--- Where the job is ended under a command that keeps its output in
--- files, the failures step says the end of what it said, once it is named;
--- one that ended is not named any more.
local function test_the_failures_step_says_the_end_of_a_command_the_job_was_ended_under(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic-ci"))
  local lines: mut {string} = {}
  for n = 1, 150 do lines[#lines + 1] = "line " .. tostring(n) end
  assert(Fs.write(tmp .. "/out", table.concat(lines, "\n") .. "\n"))
  assert(Fs.write(tmp .. "/err", "warning: slow"))
  local name = ""
  local printed = in_a_job(tmp, function()
    name = Failures.begin("core build", tmp .. "/out", tmp .. "/err")
    assert(Failures.command({}) == 0)
  end)
  assert(printed:find("the job was ended while core build ran; the end of what it said:\nline 51\n", 1, true) ~= nil,
    printed)
  assert(printed:find("line 50\n", 1, true) == nil and printed:find("line 150\nwarning: slow\n$") ~= nil, printed)
  local after = in_a_job(tmp, function()
    Failures.done(name)
    assert(Failures.command({}) == 0)
  end)
  assert(after:find("was ended while", 1, true) == nil, after)
end

--- Several commands can run at once, each named apart; `during` names
--- one no more once it raises, and the tail of a file of one long line
--- is cut to its last bytes.
local function test_commands_are_named_apart_and_no_more_once_they_end(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic-ci"))
  assert(Fs.write(tmp .. "/a.out", "lane a\n"))
  assert(Fs.write(tmp .. "/b.out", string.rep("b", 40000)))
  local printed = in_a_job(tmp, function()
    local a = Failures.begin("fixture: a", tmp .. "/a.out", tmp .. "/a.err")
    local _ = Failures.begin("fixture: b", tmp .. "/b.out", tmp .. "/b.err")
    local ran, why = pcall(Failures.during, "suite", tmp .. "/a.out", tmp .. "/a.err", function()
      error("gone", 0)
    end)
    assert(not ran and why == "gone", tostring(why))
    Failures.done(a)
    assert(Failures.command({}) == 0)
  end)
  assert(printed:find("fixture: a ran", 1, true) == nil and printed:find("suite ran", 1, true) == nil, printed)
  local said = assert(printed:match("while fixture: b ran; the end of what it said:\n(b+)\n$"), printed)
  assert(#said == 16384, tostring(#said))
end

--- The end of a long text said again starts at a line.
local function test_the_end_of_a_long_text_starts_at_a_line(tmp: string)
  assert(Fs.mkdirs(tmp .. "/cosmic-ci"))
  assert(Fs.write(tmp .. "/c.out", "first\n" .. string.rep("c", 20000) .. "\nlast\n"))
  local printed = in_a_job(tmp, function()
    local _ = Failures.begin("core build", tmp .. "/c.out", tmp .. "/c.err")
    assert(Failures.command({}) == 0)
  end)
  assert(printed:find("the end of what it said:\nlast\n$") ~= nil, printed:sub(-200))
end
