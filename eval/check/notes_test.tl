--- `eval/check/notes.tl`: the evidence it reads from a build database,
--- and an arena with nothing to grade.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Notes = require("eval.check.notes")
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
  local evidence = assert(Notes.evidence(path))
  assert(evidence.tests == 2 and evidence.examples == 2,
    tostring(evidence.tests) .. " " .. tostring(evidence.examples))
end

local function test_reset_clears_the_runs_and_keeps_the_rest(dir: string)
  local path = dir .. "/build.db"
  database(path, { { "a_test.tl", "test", "file" } }, { { "a_test.tl", "1" } })
  assert(Notes.reset_evidence(path))
  local evidence = assert(Notes.evidence(path))
  assert(evidence.tests == 0 and evidence.examples == 0)
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "select count(*) from inputs", {}))
  db:close()
  assert(rows[1][1] == "1")
end

local function test_a_missing_database_resets_but_is_no_evidence(dir: string)
  local path = dir .. "/o/build.db"
  assert(Notes.reset_evidence(path))
  assert(not Fs.exists(path))
  local evidence, trouble = Notes.evidence(path)
  assert(evidence == nil and trouble:find("no build database", 1, true), trouble)
end

local function test_an_arena_without_a_project_fails(dir: string)
  assert(Notes.grade(dir) == 1)
end

local function test_a_failure_in_cosmic_is_one_a_line_of_stderr_opens_with()
  assert(Notes.failed_in_cosmic("cosmic: launcher: no payload\n"))
  assert(Notes.failed_in_cosmic("notes: no note 9\ncosmic: runtime error\n"))
  assert(not Notes.failed_in_cosmic("notes: no note 9 (cosmic)\n"))
end

local function test_a_signal_is_a_status_as_a_shell_reports_it()
  assert(Notes.status({ code = 3, ok = false, timed_out = false, captured = {}, truncated = false }) == 3)
  assert(Notes.status({ signal = 11, ok = false, timed_out = false, captured = {}, truncated = false }) == 139)
end

--- Grades the arena at `dir` with its lines -- written to stdout --
--- taken into a file there, and answers its status and those lines.
local function graded(dir: string): integer, string
  local lines = dir .. "/graded.out"
  local out = assert(sys.open(lines, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
  local saved = assert(sys.dup(1))
  assert(sys.dup2(out, 1))
  assert(sys.close(out))
  local ok, status = pcall(Notes.grade, dir)
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
  local status, said = graded(dir)
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
  local status, said = graded(dir)
  assert(status == 1, said)
  -- The stand-in cosmic ran, and passed the build without naming notes.
  assert(said:find("check: ok   " .. dir .. "/bin/cosmic build\n", 1, true), said)
  assert(said:find("check: FAIL cosmic build did not produce o/bin/notes", 1, true), said)
  assert(not Fs.exists(dir .. "/empty"), "the earlier binary was run")
end

local function test_built_notes_reads_the_build_line()
  assert(Notes.built_notes("build: 4 modules\nbuild: PASS (o/bin/notes, 433 ms)\n"))
  assert(Notes.built_notes("build: PASS (o/bin/hello, o/bin/notes, 12 ms)\n"))
  assert(not Notes.built_notes("build: PASS (o/bin/notes2, 12 ms)\n"))
  assert(not Notes.built_notes("build: PASS (no executable: no cmd/<name>/main.tl)\n"))
  assert(not Notes.built_notes("build: FAIL\n"))
end
