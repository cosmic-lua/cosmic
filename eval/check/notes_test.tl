--- `eval/check/notes.tl`: the evidence it reads from a build database,
--- and an arena with nothing to grade.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Notes = require("eval.check.notes")

--- A build database with the two tables the evidence reads: one input
--- per path, and one run per passing or failing test.
local function database(path: string, inputs: {{string}}, runs: {{string}})
  local db = assert(Sqlite.open(path, true))
  assert(Sqlite.exec(db, [[
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
  Sqlite.close(db)
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
  local tests, examples = Notes.evidence(path)
  assert(tests == 2 and examples == 2, tostring(tests) .. " " .. tostring(examples))
end

local function test_reset_clears_the_runs_and_keeps_the_rest(dir: string)
  local path = dir .. "/build.db"
  database(path, { { "a_test.tl", "test", "file" } }, { { "a_test.tl", "1" } })
  assert(Notes.reset_evidence(path))
  local tests, examples = Notes.evidence(path)
  assert(tests == 0 and examples == 0)
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "select count(*) from inputs", {}))
  Sqlite.close(db)
  assert(rows[1][1] == "1")
end

local function test_a_missing_database_resets_but_is_no_evidence(dir: string)
  local path = dir .. "/o/build.db"
  assert(Notes.reset_evidence(path))
  assert(not Fs.exists(path))
  local tests, _, trouble = Notes.evidence(path)
  assert(tests == nil and trouble:find("no build database", 1, true), trouble)
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
