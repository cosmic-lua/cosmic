local fs = require("cosmic.fs")
local check = require("cosmic.check")
local journal = require("_eval.journal")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- @return string A fresh, empty scratch directory
local function scratch_dir(): string
  local dir = fs.join(tmpdir,
    "journal-scratch-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.make_dirs(dir))
  return dir
end

local function test_clean_self_report_and_friction_parse()
  local j = journal.parse("_eval/testdata/run_pass/json-cli")
  assert(j.self_report_clean == true,
    "run_pass's NOTES.md (f) should parse as clean, got " .. tostring(j.self_report_clean))
  assert(#j.friction == 2, "expected 2 friction items, got " .. #j.friction)
  assert(j.friction[1]:find("flags module docs", 1, true) ~= nil,
    "friction items should be verbatim, got: " .. tostring(j.friction[1]))
end
test_clean_self_report_and_friction_parse()

local function test_final_txt_attempts_parse()
  local j = journal.parse("_eval/testdata/run_pass/json-cli")
  assert(j.attempts_first_build == 2,
    "expected attempts_first_build 2, got " .. tostring(j.attempts_first_build))
  assert(j.attempts_green_ci == 3,
    "expected attempts_green_ci 3, got " .. tostring(j.attempts_green_ci))
end
test_final_txt_attempts_parse()

local function test_unparseable_final_txt_leaves_attempts_nil()
  local j = journal.parse("_eval/testdata/run_partial/text-report")
  assert(j.attempts_first_build == nil,
    "a one-line final.txt should leave attempts_first_build nil, got " ..
    tostring(j.attempts_first_build))
  assert(j.attempts_green_ci == nil,
    "a one-line final.txt should leave attempts_green_ci nil, got " ..
    tostring(j.attempts_green_ci))
end
test_unparseable_final_txt_leaves_attempts_nil()

local function test_missing_files_leave_everything_nil()
  local dir = scratch_dir()
  local j = journal.parse(dir)
  assert(j.self_report_clean == nil, "missing NOTES.md should leave self_report_clean nil")
  assert(#j.friction == 0, "missing NOTES.md should leave friction empty")
  assert(j.attempts_first_build == nil, "missing final.txt should leave attempts_first_build nil")
  assert(j.attempts_green_ci == nil, "missing final.txt should leave attempts_green_ci nil")
end
test_missing_files_leave_everything_nil()

local function test_contaminated_self_report_is_not_clean()
  local dir = scratch_dir()
  check.must(fs.write(fs.join(dir, "NOTES.md"), table.concat({
          "## (f) Context self-report",
          "(i) None.",
          "(ii) Yes, I recognized cosmic from prior training.",
        }, "\n")))
  local j = journal.parse(dir)
  assert(j.self_report_clean == false,
    "an admitted-familiarity self-report should parse as not clean, got " ..
    tostring(j.self_report_clean))
end
test_contaminated_self_report_is_not_clean()

local function test_ambiguous_self_report_stays_nil()
  local dir = scratch_dir()
  check.must(fs.write(fs.join(dir, "NOTES.md"), table.concat({
          "## (f) Context self-report",
          "I am not entirely sure how to answer this.",
        }, "\n")))
  local j = journal.parse(dir)
  assert(j.self_report_clean == nil,
    "an answer that is neither a clear denial nor an admission must stay nil, got " ..
    tostring(j.self_report_clean))
end
test_ambiguous_self_report_stays_nil()

local function test_friction_markers_are_stripped()
  local dir = scratch_dir()
  check.must(fs.write(fs.join(dir, "NOTES.md"), table.concat({
          "## (b) Friction points",
          "1. first item",
          "- second item",
          "* third item",
          "## (c) next section",
          "not a friction item",
        }, "\n")))
  local j = journal.parse(dir)
  assert(#j.friction == 3, "expected 3 friction items, got " .. #j.friction)
  assert(j.friction[1] == "first item", "got: " .. tostring(j.friction[1]))
  assert(j.friction[2] == "second item", "got: " .. tostring(j.friction[2]))
  assert(j.friction[3] == "third item", "got: " .. tostring(j.friction[3]))
end
test_friction_markers_are_stripped()

local function test_last_occurrence_of_a_heading_wins()
  local dir = scratch_dir()
  check.must(fs.write(fs.join(dir, "NOTES.md"), table.concat({
          "## (a) Journey log",
          "along the way I wrote (b) into a shell command by mistake",
          "## (b) Friction points",
          "- the real friction item",
        }, "\n")))
  local j = journal.parse(dir)
  assert(#j.friction == 1, "expected 1 friction item, got " .. #j.friction)
  assert(j.friction[1] == "the real friction item", "got: " .. tostring(j.friction[1]))
end
test_last_occurrence_of_a_heading_wins()
