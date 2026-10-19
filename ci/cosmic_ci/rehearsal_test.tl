local Fs = require("cosmic.fs")
local Rehearsal = require("cosmic_ci.rehearsal")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "/parent/testdata/gate/rehearsal.txt", letters = "r" } } }

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
  assert(#more == 3 and more[1]:find("cosmic/removed_example.tl method_in_record failed and testdata/gate/rehearsal.txt does not expect it", 1, true) ~= nil,
    table.concat(more, "\n"))
  allowed["lang/gone_test.tl test_old"] = "a test that passes now"
  local stale = Rehearsal.judge(allowed, failed)
  assert(#stale == 1 and stale[1]:find("lang/gone_test.tl test_old is listed in testdata/gate/rehearsal.txt and did not fail: remove the entry",
    1, true) ~= nil, table.concat(stale, "\n"))
end

local function test_a_refused_file_stays_expected_for_its_code_alone()
  local allowed: {string: string} = { ["cosmic/removed_example.tl method_in_record"] = "the example is the removed form" }
  local other = Rehearsal.failures("test: FAIL  cosmic/removed_example.tl:12:1: a name is missing (unknown_variable): declare it\n")
  local told = Rehearsal.judge(allowed, other)
  assert(#told == 2 and told[1]:find("cosmic/removed_example.tl unknown_variable failed", 1, true) ~= nil and
      told[2]:find("cosmic/removed_example.tl method_in_record is listed", 1, true) ~= nil, table.concat(told, "\n"))
  -- a module not compiled for requiring a refused one has no code of its own
  local cascade = Rehearsal.failures("test: FAIL  build/a.tl: not compiled: it requires b, which the new checker refused\n")
  assert(cascade[1] == "build/a.tl")
end

local function test_the_list_the_tree_holds_is_well_formed()
  local text = assert(Fs.read(Test.parent("testdata/gate/rehearsal.txt")))
  local listed, why = Rehearsal.parse(text)
  assert(listed ~= nil, tostring(why))
end
