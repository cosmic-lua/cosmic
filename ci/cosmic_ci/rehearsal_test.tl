local Fs = require("cosmic.fs")
local Rehearsal = require("cosmic_ci.rehearsal")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "/parent/testdata/gate/rehearsal.txt", letters = "r" }, { path = "/parent/testdata/rehearsal/project/queue_test.tl", letters = "r" },
  { path = "/parent/testdata/rehearsal/project/report_test.tl", letters = "r" },
  { path = "/parent/testdata/rehearsal/fork_only/lookup_test.tl", letters = "r" },
  { path = "/parent/testdata/rehearsal/fork_only/cache_test.tl", letters = "r" } } }

--- Whether line `at` of `lines` holds `text`.
local function says(lines: {string}, at: integer, text: string): boolean
  local line = lines[at]
  return line ~= nil and line:find(text, 1, true) ~= nil
end

local function test_a_list_is_entries_with_reasons_and_comments()
  local listed = assert(Rehearsal.parse("# why the list exists\n\nbuild/x_test.tl test_a -- prints the fork's hint\n" ..
      "cosmic/removed_example.tl -- the tour uses a tuple\n"))
  assert(listed["build/x_test.tl test_a"] == "prints the fork's hint", tostring(listed["build/x_test.tl test_a"]))
  assert(listed["cosmic/removed_example.tl"] == "the tour uses a tuple")
end

local function test_an_entry_without_a_reason_or_listed_twice_is_refused()
  local none, why = Rehearsal.parse("build/x_test.tl test_a\n")
  assert(none == nil and why:find("testdata/gate/rehearsal.txt:1: expected `<failure> -- <reason>`", 1, true) ~= nil, tostring(why))
  local empty, empty_why = Rehearsal.parse("build/x_test.tl test_a -- \n")
  assert(empty == nil and empty_why:find(":1:", 1, true) ~= nil, tostring(empty_why))
  local twice, twice_why = Rehearsal.parse("a -- one\n# between\na -- two\n")
  assert(twice == nil and twice_why:find(":3: `a` is listed twice", 1, true) ~= nil, tostring(twice_why))
end

local OUTPUT <const> = table.concat({
  "test: sandbox: each worker is held to its inputs, the tree at /tree",
  "test: FAIL  build/x_test.tl test_a: expected 1, got 2",
  "  hint: read the message",
  "  rerun: cosmic test 'build/x_test.tl test_a'",
  "test: FAIL  cosmic/removed_example.tl:279:3: `function Friendly:greet` is not in the grammar: declare it (method_in_record): fix",
  "test: FAIL  build/x_test.tl test_a: expected 1, got 2",
  "test: FAIL  core/boot.c:report: a C function no test enters",
  "test: FAIL  cosmic/json.tl: the compiler refused it",
  "cosmic/json.tl:12:3: something (code): fix",
  "test: 4 of 90 tests failed, 0 infrastructure errors, 12 ms",
}, "\n")

local function test_the_failures_of_a_run_are_named_once_each_by_test_or_file()
  local failed = Rehearsal.failures(OUTPUT)
  assert(table.concat(failed, "|") == "build/x_test.tl test_a|cosmic/removed_example.tl method_in_record|core/boot.c:report|cosmic/json.tl code",
    table.concat(failed, "|"))
  assert(#Rehearsal.failures("test: 12 tests passed in 3 modules\n") == 0)
end

local function test_a_failure_the_list_lacks_and_an_entry_that_did_not_fail_are_both_told()
  local allowed: {string: string} = {
    ["build/x_test.tl test_a"] = "a", ["cosmic/removed_example.tl method_in_record"] = "b", ["core/boot.c:report"] = "c",
    ["cosmic/json.tl code"] = "d",
  }
  local failed = Rehearsal.failures(OUTPUT)
  assert(#Rehearsal.judge(allowed, failed) == 0)
  local more = Rehearsal.judge({ ["build/x_test.tl test_a"] = "a" }, failed)
  assert(#more == 3 and says(more, 1, "cosmic/removed_example.tl method_in_record failed and testdata/gate/rehearsal.txt does not expect it"),
    table.concat(more, "\n"))
  allowed["lang/gone_test.tl test_old"] = "a test that passes now"
  local stale = Rehearsal.judge(allowed, failed)
  assert(#stale == 1 and says(stale, 1, "lang/gone_test.tl test_old is listed in testdata/gate/rehearsal.txt and did not fail: remove the entry"), table.concat(stale, "\n"))
end

local function test_a_refused_file_stays_expected_for_its_code_alone()
  local allowed: {string: string} = { ["cosmic/removed_example.tl method_in_record"] = "the example is the removed form" }
  local other = Rehearsal.failures("test: FAIL  cosmic/removed_example.tl:12:1: a name is missing (unknown_variable): declare it\n")
  local told = Rehearsal.judge(allowed, other)
  assert(#told == 2 and says(told, 1, "cosmic/removed_example.tl unknown_variable failed") and
      says(told, 2, "cosmic/removed_example.tl method_in_record is listed"), table.concat(told, "\n"))
  -- a module not compiled for requiring a refused one has no code of its own
  local cascade = Rehearsal.failures("test: FAIL  build/a.tl: not compiled: it requires b, which the new checker refused\n")
  assert(cascade[1] == "build/a.tl")
end

local function test_the_list_the_tree_holds_is_well_formed()
  local text = assert(Fs.read(Test.parent("testdata/gate/rehearsal.txt")))
  local listed, why = Rehearsal.parse(text)
  assert(listed ~= nil, tostring(why))
end

--- What the tool said of the two projects, as the run printed it.
local PROJECT_OUTPUT <const> = table.concat({
  "build: 4 modules (2 compiled, 2 cached; 4 sources parsed; 4 files staged, 4 read) in 545 ms",
  "test: coverage 97.6% (41/42 lines; informational, never a failure)",
  "test: 3 tests passed in 2 modules; 3 ran, 0 stood, 576 ms; sandboxed, under a policy",
  "",
}, "\n")

local FORK_ONLY_OUTPUT <const> = table.concat({
  "build: 0 modules (0 compiled, 0 cached; 3 sources parsed; 4 files staged, 4 read) in 482 ms",
  "test: FAIL  cache.tl:8:1: `function Kv.Lru.get` has more than one dot (function_path): assign the function to the field: " ..
    "`Kv.Lru.get = function(...) ... end`",
  "test: FAIL  cache_test.tl: not compiled: it requires cache, which the new checker refused",
  "test: FAIL  lookup.tl: the compiler refused it",
  "lookup.tl:10:12: nil is given as return value 1, where `Entry` is wanted (nil_not_allowed): give a value, or declare what " ..
    "takes it `Entry?` (a parameter or field `name?: T`)",
  "lookup.tl: 1 error of nil_not_allowed in its bodies; follow the fix above",
  "test: FAIL  lookup_test.tl: not compiled: it requires lookup, which the new checker refused",
  "test: coverage 0.0% (0/0 lines; informational, never a failure)",
  "test: 4 of 4 tests failed, 0 infrastructure errors, 593 ms; sandboxed, under a policy",
  "",
}, "\n")

local function test_a_project_of_teal_both_checkers_read_passes_and_one_of_forms_only_the_fork_reads_is_refused_with_the_fix()
  assert(#Rehearsal.judge_project("project", 0, PROJECT_OUTPUT) == 0)
  assert(#Rehearsal.judge_project("fork_only", 1, FORK_ONLY_OUTPUT) == 0)
end

local function test_a_project_that_does_what_the_other_does_is_told()
  -- the project refused, and the fork-only one passing
  local refused = Rehearsal.judge_project("project", 1, FORK_ONLY_OUTPUT)
  assert(#refused == 2 and table.concat(refused, "\n"):find("exit 1, not 0.*its 3 tests in 2 modules passed") ~= nil,
    table.concat(refused, "\n"))
  local passed = Rehearsal.judge_project("fork_only", 0, PROJECT_OUTPUT)
  assert(#passed == 5 and table.concat(passed, "\n"):find("exit 0, not 1", 1, true) ~= nil, table.concat(passed, "\n"))
  assert(#Rehearsal.judge_project("nobody", 0, "") == 1)
end

--- Each word the fork-only project's run must say is held by a run that leaves it out.
local function test_each_thing_a_projects_run_must_say_is_asked_for()
  for _, left_out in ipairs({ "(nil_not_allowed)", "`Entry?`", "(function_path)", "`Kv.Lru.get = function(...) ... end`",
      "lookup, which the new checker refused", "test: 4 of 4 tests failed" }) do
    local at = assert(FORK_ONLY_OUTPUT:find(left_out, 1, true))
    local cut = FORK_ONLY_OUTPUT:sub(1, at - 1) .. "x" .. FORK_ONLY_OUTPUT:sub(at + #left_out)
    assert(#Rehearsal.judge_project("fork_only", 1, cut) >= 1, left_out .. " is not asked for")
  end
  assert(#Rehearsal.judge_project("project", 0, (PROJECT_OUTPUT:gsub("3 tests passed", "2 tests passed"))) == 1)
end

local function test_an_error_of_a_project_speaks_of_no_pin()
  local pinned = FORK_ONLY_OUTPUT:gsub("in its bodies;", "in its bodies, pinned 0;")
  local told = Rehearsal.judge_project("fork_only", 1, pinned)
  assert(#told == 1 and table.concat(told):find("speaks of `pinned`", 1, true) ~= nil, table.concat(told, "\n"))
end

local function test_a_run_that_built_the_tool_again_ran_on_another_tool()
  assert(#Rehearsal.judge_tool("test: 5 tests passed\n", "") == 0)
  for _, said in ipairs({ "cosmic: the tool is stale; rebuilding it from the tree",
      "cosmic: the tool's database was built by other code than its own; building it again" }) do
    local told = Rehearsal.judge_tool("", said .. "\n")
    assert(#told == 1 and table.concat(told):find("built the tool again", 1, true) ~= nil, said)
  end
end

--- The tests of each project are there, and each project has something asked of it.
local function test_the_projects_of_the_rehearsal_are_there()
  local tests: {string: {string}} = {
    project = { "queue_test.tl", "report_test.tl" }, fork_only = { "lookup_test.tl", "cache_test.tl" },
  }
  for _, name in ipairs(Rehearsal.projects()) do
    local files = tests[name]
    assert(files ~= nil and #files == 2, name .. " has no tests named")
    for _, file in ipairs(files) do
      local text = assert(Fs.read(Test.parent("testdata/rehearsal/" .. name .. "/" .. file)))
      assert(text:find("local function test_", 1, true) ~= nil, name .. "/" .. file .. " holds no test")
    end
    assert(#Rehearsal.judge_project(name, 0, "") >= 1, name .. " has nothing asked of it")
  end
end
