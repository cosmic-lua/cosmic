--- `eval/check/grade.tl`: the evidence it reads from a build database,
--- the journal it requires, an arena with nothing to grade, and a build
--- that vouches for no executable.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local Grader = require("eval.check.grade")
local stand_in = require("build.stand_in")

--- A build database with the two tables the evidence reads: one input
--- per path, and one run per passing or failing test.
local function database(path: string, inputs: {{string}}, runs: {{string}})
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec([[
    create table inputs (path text primary key, kind text, origin text);
    create table runs (path text, passed integer);
  ]]))
  for _, input in ipairs(inputs) do
    assert(Sqlite.run(db, "insert into inputs values (?, ?, ?)",
      { { text = input[1] }, { text = input[2] }, { text = input[3] } }))
  end
  for _, run in ipairs(runs) do
    assert(Sqlite.run(db, "insert into runs values (?, ?)",
      { { text = run[1] }, { integer = math.tointeger(tonumber(run[2])) } }))
  end
  db:close()
end

local function test_evidence_counts_passing_tests_and_examples_apart(dir: string)
  local path = dir .. "/build.db"
  database(path, {
    { "a_test.tl", "test", "file" },
    { "b_test.tl", "test", "file" },
    { "a_example.tl", "example", "file" },
    { "guide.md", "test", "doctest" },
  }, {
    { "a_test.tl", "1" }, { "a_test.tl", "1" }, { "b_test.tl", "0" },
    { "a_example.tl", "1" }, { "guide.md", "1" },
  })
  local evidence = assert(Grader.evidence(path))
  assert(evidence.tests == 2 and evidence.examples == 2,
    tostring(evidence.tests) .. " " .. tostring(evidence.examples))
end

local function test_reset_clears_the_runs_and_keeps_the_rest(dir: string)
  local path = dir .. "/build.db"
  database(path, { { "a_test.tl", "test", "file" } }, { { "a_test.tl", "1" } })
  assert(Grader.reset_evidence(path))
  local evidence = assert(Grader.evidence(path))
  assert(evidence.tests == 0 and evidence.examples == 0)
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "select count(*) from inputs", {}))
  db:close()
  assert(rows[1][1] == "1")
end

local function test_a_missing_database_resets_but_is_no_evidence(dir: string)
  local path = dir .. "/o/build.db"
  assert(Grader.reset_evidence(path))
  assert(not Fs.exists(path))
  local evidence, trouble = Grader.evidence(path)
  assert(evidence == nil and trouble:find("no build database", 1, true), trouble)
end

local function test_a_failure_in_cosmic_is_one_a_line_of_stderr_opens_with()
  assert(Grader.failed_in_cosmic("cosmic: launcher: no payload\n"))
  assert(Grader.failed_in_cosmic("notes: no note 9\ncosmic: runtime error\n"))
  assert(not Grader.failed_in_cosmic("notes: no note 9 (cosmic)\n"))
end

local function test_a_signal_is_a_status_as_a_shell_reports_it()
  assert(Grader.status({ code = 3, ok = false, timed_out = false, captured = {}, truncated = false }) == 3)
  assert(Grader.status({ signal = 11, ok = false, timed_out = false, captured = {}, truncated = false }) == 139)
end

--- Grades the arena at `dir` for the task `name` with its lines --
--- written to stdout -- taken into a file there, and answers its
--- status and those lines. The hidden API tests are under
--- `dir`/testdata.
local function graded(name: string, dir: string): integer, string
  local lines = dir .. "/graded.out"
  local out = assert(sys.open(lines, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
  local saved = assert(sys.dup(1))
  assert(sys.dup2(out, 1))
  assert(sys.close(out))
  local ok, status = pcall(Grader.grade, name, dir, dir .. "/testdata")
  assert(sys.dup2(saved, 1))
  assert(sys.close(saved))
  if not ok then error(status, 0) end
  return status as integer, (assert(Fs.read(lines)))
end

--- A build that fails leaves an earlier o/bin/notes where it was, and
--- the grader must not run that one as if it were this project's.
local function test_a_failed_build_does_not_run_an_earlier_binary(dir: string)
  assert(Fs.mkdirs(dir .. "/bin") and Fs.mkdirs(dir .. "/project/o/bin"))
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(stand_in.place(probe, dir .. "/bin/cosmic",
    "[build] eprint build: FAIL\n[build] exit 1\nexit 0"))
  assert(stand_in.place(probe, dir .. "/project/o/bin/notes", "print 1"))
  local status, said = graded("notes", dir)
  assert(status == 1, said)
  -- The stand-in cosmic ran, and failed the build alone.
  assert(said:find("check: ok   " .. dir .. "/bin/cosmic test\n", 1, true), said)
  assert(said:find("check: FAIL " .. dir .. "/bin/cosmic build\n", 1, true), said)
  assert(said:find("skip o/bin/notes: cosmic build failed", 1, true), said)
  assert(not Fs.exists(dir .. "/empty"), "the earlier binary was run")
  assert(Fs.exists(dir .. "/project/o/bin/notes"), "the solver's binary was removed")
end

--- A build that passes without writing notes (cmd/notes renamed away)
--- vouches for nothing: the earlier o/bin/notes is not run, and
--- the grade fails for want of one.
local function test_a_build_that_did_not_write_notes_does_not_run_an_earlier_one(dir: string)
  assert(Fs.mkdirs(dir .. "/bin") and Fs.mkdirs(dir .. "/project/o/bin"))
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(stand_in.place(probe, dir .. "/bin/cosmic",
    "[build] print build: PASS (no executable: no cmd/<name>/main.tl)\nexit 0"))
  assert(stand_in.place(probe, dir .. "/project/o/bin/notes", "print 1"))
  local status, said = graded("notes", dir)
  assert(status == 1, said)
  -- The stand-in cosmic ran, and passed the build without naming notes.
  assert(said:find("check: ok   " .. dir .. "/bin/cosmic build\n", 1, true), said)
  assert(said:find("check: FAIL cosmic build did not produce o/bin/notes", 1, true), said)
  assert(not Fs.exists(dir .. "/empty"), "the earlier binary was run")
end

local function test_built_reads_the_build_line()
  assert(Grader.built("build: 4 modules\nbuild: PASS (o/bin/notes, 433 ms)\n", "notes"))
  assert(Grader.built("build: PASS (o/bin/hello, o/bin/notes, 12 ms)\n", "notes"))
  assert(not Grader.built("build: PASS (o/bin/notes2, 12 ms)\n", "notes"))
  assert(not Grader.built("build: PASS (no executable: no cmd/<name>/main.tl)\n", "notes"))
  assert(not Grader.built("build: FAIL\n", "notes"))
end

local function test_an_arena_without_a_project_fails_every_task(dir: string)
  for _, name in ipairs({ "notes", "pack", "ledger", "kv", "jobs", "mirror", "relay" }) do
    local status, said = graded(name, dir)
    assert(status == 1, said)
    assert(said:find("check: FAIL no project at " .. dir .. "/project", 1, true), said)
    assert(said:sub(-12) == "check: FAIL\n", said)
  end
end

--- A build that fails runs no earlier binary, whichever task it is.
local function test_a_failed_build_runs_no_binary_for_any_task(dir: string)
  assert(Fs.mkdirs(dir .. "/bin") and Fs.mkdirs(dir .. "/project/o/bin"))
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(stand_in.place(probe, dir .. "/bin/cosmic",
    "[build] eprint build: FAIL\n[build] exit 1\nexit 0"))
  for _, name in ipairs({ "pack", "ledger", "kv", "jobs", "mirror", "relay" }) do
    assert(stand_in.place(probe, dir .. "/project/o/bin/" .. name, "print 1"))
    local status, said = graded(name, dir)
    assert(status == 1, said)
    assert(said:find("skip o/bin/" .. name .. ": cosmic build failed", 1, true), said)
    -- A copy of the checked core is 39.5 MB and a worker's directory is in
    -- a 256 MiB tmpfs: one task's stand-in at a time stays inside it.
    assert(Fs.remove(dir .. "/project/o/bin/" .. name))
    assert(Fs.remove(dir .. "/project/o/bin/" .. name .. ".do"))
  end
  assert(not Fs.exists(dir .. "/empty"), "a binary was run")
end

local function test_an_unknown_task_is_a_usage_error()
  assert(Grader.main({ "chess", "/nowhere" }) == 2)
  assert(Grader.main({ "notes" }) == 2)
  assert(Grader.main({ "notes", "/nowhere", "extra" }) == 2)
end

local function test_a_journal_is_a_regular_file_with_something_in_it(dir: string)
  local path = dir .. "/JOURNAL.md"
  local kept, why = Grader.journal(path)
  assert(not kept and why == "no " .. path, why)
  assert(Fs.write(path, ""))
  kept, why = Grader.journal(path)
  assert(not kept and why == path .. " is empty", why)
  assert(Fs.write(path, " \n\t\n"))
  kept, why = Grader.journal(path)
  assert(not kept and why == path .. " is empty", why)
  assert(Fs.write(path, "**Log**\n\n1. tried it\n"))
  assert(Grader.journal(path))
  -- Neither a link to a journal nor a pipe, which a read would wait on,
  -- is one.
  assert(Fs.mkdirs(dir .. "/dir.md"))
  assert(Fs.symlink(path, dir .. "/link.md"))
  assert(sys.mkfifo(dir .. "/pipe.md", 420))
  for _, name in ipairs({ "dir.md", "link.md", "pipe.md" }) do
    local other = dir .. "/" .. name
    kept, why = Grader.journal(other)
    assert(not kept and why == other .. " is not a regular file", why)
  end
end

--- Grades the arena at `dir`, whose project's JOURNAL.md holds
--- `journal` (none when nil), with a stand-in cosmic whose every
--- command passes and whose `fix` fails where the journal was not set
--- aside; answers the status and lines.
local function graded_with_journal(dir: string, journal: string | nil): integer, string
  assert(Fs.mkdirs(dir .. "/bin") and Fs.mkdirs(dir .. "/project"))
  if journal ~= nil then
    assert(Fs.write(dir .. "/project/JOURNAL.md", journal))
  end
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(stand_in.place(probe, dir .. "/bin/cosmic",
    "[fix] exists JOURNAL.md 1\nexit 0"))
  return graded("kv", dir)
end

local function test_a_project_without_a_journal_fails(dir: string)
  local status, said = graded_with_journal(dir, nil)
  assert(status == 1, said)
  assert(said:find("check: FAIL JOURNAL.md kept, as TASK.md's journal contract asks: no " ..
      dir .. "/project/JOURNAL.md\n", 1, true), said)
  assert(said:sub(-12) == "check: FAIL\n", said)
end

local function test_a_project_with_an_empty_journal_fails(dir: string)
  local status, said = graded_with_journal(dir, "\n  \n")
  assert(status == 1, said)
  assert(said:find("check: FAIL JOURNAL.md kept, as TASK.md's journal contract asks: " ..
      dir .. "/project/JOURNAL.md is empty\n", 1, true), said)
  assert(Fs.read(dir .. "/project/JOURNAL.md") == "\n  \n")
end

--- A journal passes its check, is set aside for `fix --check`, and is
--- put back after it.
local function test_a_project_with_a_journal_passes_that_check(dir: string)
  local status, said = graded_with_journal(dir, "**Log**\n\n1. tried it\n")
  assert(status == 1, said) -- the stand-in builds no kv
  assert(said:find("check: ok   JOURNAL.md kept, as TASK.md's journal contract asks\n", 1, true), said)
  assert(said:find("check: ok   " .. dir .. "/bin/cosmic fix --check\n", 1, true), said)
  assert(Fs.read(dir .. "/project/JOURNAL.md") == "**Log**\n\n1. tried it\n")
  assert(not Fs.exists(dir .. "/JOURNAL.md.aside"))
end

--- A journal an earlier, killed grading left aside is put back before
--- it is checked.
local function test_a_journal_left_aside_is_put_back_and_checked(dir: string)
  assert(Fs.write(dir .. "/JOURNAL.md.aside", "kept\n"))
  local status, said = graded_with_journal(dir, nil)
  assert(status == 1, said)
  assert(said:find("check: ok   JOURNAL.md kept, as TASK.md's journal contract asks\n", 1, true), said)
  assert(Fs.read(dir .. "/project/JOURNAL.md") == "kept\n")
end

--- An earlier grading's aside beside a new journal is kept, and the
--- new journal is the one checked and left in place.
local function test_a_journal_beside_an_earlier_aside_is_the_one_checked(dir: string)
  assert(Fs.write(dir .. "/JOURNAL.md.aside", "kept\n"))
  local status, said = graded_with_journal(dir, " \n")
  assert(status == 1, said)
  assert(said:find("is an earlier grading's, beside a new JOURNAL.md", 1, true), said)
  assert(said:find(dir .. "/project/JOURNAL.md is empty\n", 1, true), said)
  -- The new journal stayed in place through `fix --check`, which the
  -- stand-in fails on finding it.
  assert(said:find("check: FAIL " .. dir .. "/bin/cosmic fix --check\n", 1, true), said)
  assert(Fs.read(dir .. "/JOURNAL.md.aside") == "kept\n")
  assert(Fs.read(dir .. "/project/JOURNAL.md") == " \n")
end

local function test_api_failures_names_each_failing_test_and_refused_line()
  local failures = Grader.api_failures(table.concat({
    "build: 3 modules",
    "test: FAIL  kv_api_test test_lru: kv_api_test:10: evicted b",
    "  its directory is kept: /tmp/x/real",
    "test: FAIL  kv_api_test test_keys: kv_api_test:20: boom",
    "second line",
    "test: FAIL (2 of 3 failed, 0 infrastructure errors, 336 ms; sandboxed)",
  }, "\n"))
  assert(#failures == 2, table.concat(failures, "; "))
  assert(failures[1] == "test_lru: kv_api_test:10: evicted b", failures[1])
  assert(failures[2] == "test_keys: kv_api_test:20: boom", failures[2])
  failures = Grader.api_failures("cosmic: kv_api_test.tl: the compiler refused it\n" ..
      "kv_api_test.tl:1:12: module not found: 'kv'\ntest: FAIL\n")
  assert(#failures == 1, table.concat(failures, "; "))
  assert(failures[1] == "does not compile: kv_api_test.tl:1:12: module not found: 'kv'",
    failures[1])
  local refusals: {string} = { "cosmic: kv_api_test.tl: the compiler refused it" }
  for i = 1, 7 do
    refusals[#refusals + 1] = "kv_api_test.tl:" .. i .. ":1: unknown type kv.Lru"
  end
  failures = Grader.api_failures(table.concat(refusals, "\n"))
  assert(#failures == 6, table.concat(failures, "; "))
  assert(failures[5] == "does not compile: kv_api_test.tl:5:1: unknown type kv.Lru", failures[5])
  assert(failures[6] == "does not compile: 2 more lines", failures[6])
  failures = Grader.api_failures("cosmic: killed\n")
  assert(#failures == 1 and failures[1] == "cosmic test failed: cosmic: killed", failures[1])
  assert(#Grader.api_failures("test: PASS (3 tests, 1 module; 3 ran)\n") == 0)
end

--- Grades a kv arena whose stand-in cosmic, run in a directory holding
--- kv_api_test.tl, lists that directory, writes a file and the
--- directory's path, and answers `lines` and `code`: as a hidden API
--- test that ran on a copy of the project. Answers the status and the
--- grader's lines.
local function graded_api(dir: string, lines: {string}, code: integer): integer, string
  assert(Fs.mkdirs(dir .. "/bin") and Fs.mkdirs(dir .. "/project/o") and
      Fs.mkdirs(dir .. "/testdata"))
  assert(Fs.write(dir .. "/project/kv.tl", "return {}\n"))
  assert(Fs.write(dir .. "/project/o/marker", "built\n"))
  assert(Fs.write(dir .. "/testdata/kv_api_test.tl", "-- hidden\n"))
  local script = { "[test] present kv_api_test.tl || exit 0", "[test] ls .",
    "[test] write leftover.txt written by the hidden test", "[test] cwd " .. dir .. "/copy.txt" }
  for _, line in ipairs(lines) do
    script[#script + 1] = "[test] print " .. line
  end
  script[#script + 1] = "[test] exit " .. code
  script[#script + 1] = "exit 0"
  local probe = assert(stand_in.build(dir .. "/stand-in"))
  assert(stand_in.place(probe, dir .. "/bin/cosmic", table.concat(script, "\n")))
  return graded("kv", dir)
end

--- The hidden test runs on a copy of the project without its o/, and
--- neither it nor what it writes reaches the project; each failing
--- test is a check that fails.
local function test_a_hidden_test_runs_on_a_copy_and_reports_each_failure(dir: string)
  local status, said = graded_api(dir, {
    "test: FAIL  kv_api_test test_lru: kv_api_test:3: evicted the wrong key",
    "test: FAIL (1 of 1 failed)" }, 1)
  assert(status == 1, said)
  assert(said:find("check: FAIL hidden api: test_lru: kv_api_test:3: evicted the wrong key\n",
    1, true), said)
  local listed = assert(Fs.read(dir .. "/check-5.out"))
  assert(listed:find("kv_api_test.tl\n", 1, true) and listed:find("kv.tl\n", 1, true), listed)
  assert(not listed:find("\no\n", 1, true) and not listed:match("^o\n"), listed)
  assert(not Fs.exists(dir .. "/project/kv_api_test.tl"), "the hidden test reached the project")
  assert(not Fs.exists(dir .. "/project/leftover.txt"), "the copy's writes reached the project")
  assert(Fs.read(dir .. "/project/o/marker") == "built\n")
  local copy = String.trim((assert(Fs.read(dir .. "/copy.txt"))))
  assert(copy ~= dir .. "/project" and not Fs.exists(copy), "the copy is left at " .. copy)
end

local function test_a_hidden_test_that_passes_is_one_check_that_passes(dir: string)
  local _, said = graded_api(dir, { "test: PASS (3 tests, 1 module, 3 ran)" }, 0)
  assert(said:find("check: ok   hidden api: kv_api_test.tl passes\n", 1, true), said)
  assert(not said:find("FAIL hidden api", 1, true), said)
end

--- A missing hidden test fails the grade rather than passing it unchecked.
local function test_a_missing_hidden_test_fails(dir: string)
  local status, said = graded_with_journal(dir, "**Log**\n")
  assert(status == 1, said)
  assert(said:find("check: FAIL hidden api: ", 1, true), said)
  assert(not said:find("check: ok   hidden api", 1, true), said)
end
