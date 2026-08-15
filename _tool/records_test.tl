#!/usr/bin/env cosmic
-- The grammar of what a build writes for something other than a person.
--
-- These assertions ARE the contract: CI greps these lines, `ci` grades
-- the summaries its stages wrote, and the verdict line is documented as
-- the record that survives truncation. A test that freezes a spelling
-- the printer has left behind is the failure this file exists to make
-- impossible, which is why the printers import the same module.

local records = require("_tool.records")

-- A row names the SOURCE. Eleven files in this tree are called
-- `init_test.tl`, so a basename names none of them.
local function test_display_names_the_source()
  assert(records.display("o/cosmic/fs/init_test.tl.test") ==
    "cosmic/fs/init_test.tl", "the o/ prefix and the stage suffix go")
  assert(records.display("o/cosmic/child/init_test.tl.test") ==
    "cosmic/child/init_test.tl", "and two init_test.tl are two names")
  assert(records.display("o/_make/law_test.tl.fmt") == "_make/law_test.tl",
    "every stage suffix, not just .test")
  -- The coverage lane keeps its segment: that is a true statement about
  -- which run produced the row, and the two rows are distinguishable.
  assert(records.display("o/.coverage/a_test.tl.test") ==
    ".coverage/a_test.tl", "the coverage lane stays distinguishable")
end
test_display_names_the_source()

-- The label is not a path. `display` keeps `.coverage/` so the row says
-- which run produced it, and nothing is on disk at that name -- so a
-- caller that READS the source needs the segment gone. Reading the
-- label instead is indistinguishable from an absent file, which reads
-- back as every coverage row reporting zero test functions.
local function test_source_of_names_a_readable_path()
  assert(records.source_of("o/.coverage/cosmic/sys_test.tl.test") ==
    "cosmic/sys_test.tl", "the coverage tree is not part of the path")
  assert(records.source_of("o/cosmic/sys_test.tl.test") ==
    "cosmic/sys_test.tl", "and the two lanes name the same source")
  -- Only a LEADING segment, and only the whole one: a project may have
  -- its own directory whose name starts the same way.
  assert(records.source_of("o/.coveragex/a_test.tl.test") ==
    ".coveragex/a_test.tl", "a different directory keeps its name")
  assert(records.source_of("o/a/.coverage/b_test.tl.test") ==
    "a/.coverage/b_test.tl", "and the segment is stripped only at the root")
end
test_source_of_names_a_readable_path()

-- `.test` must not strip out of `.benchmark`, which contains no `.test`
-- but shares its shape closely enough to be worth pinning.
local function test_stage_of_reads_the_suffix()
  assert(records.stage_of("o/x.benchmark") == "benchmark", "benchmark")
  assert(records.stage_of("o/x.test") == "test", "test")
  assert(records.stage_of("o/x.lua") == "", "a name with no stage has none")
end
test_stage_of_reads_the_suffix()

-- The annotation counts what the target RAN, so it belongs only to a
-- status that ran it. A skip annotated with "(7 test functions)"
-- describes work that did not happen.
local function test_the_annotation_belongs_to_work_that_happened()
  assert(records.row("pass", "a_test.tl", 7, "test functions", 12) ==
    "✓ a_test.tl (7 test functions)  12ms", "a passing row carries both")
  assert(records.row("skip", "a_test.tl", 7, "test functions", 12) ==
    "→ a_test.tl  12ms", "a skip did not run them")
  assert(records.row("fail", "a_test.tl", 7, "test functions", 12) ==
    "✗ a_test.tl  12ms", "and a failure's number is in the block below")
  assert(records.row("pass", "a_test.tl", 0, "test functions") ==
    "✓ a_test.tl", "an unrecorded count and duration print nothing")
end
test_the_annotation_belongs_to_work_that_happened()

-- counts and parse_counts are inverses: the summary a stage writes is
-- the summary its verb reads back.
local function test_counts_round_trips()
  local cases: {{integer}} = {
    {19, 0, 0}, {18, 1, 0}, {17, 1, 1}, {0, 0, 3},
  }
  for _, c in ipairs(cases) do
    local text = records.counts(c[1], c[2], c[3])
    local got = require("cosmic.check").must(records.parse_counts(text))
    assert(got.passed == c[1] and got.failed == c[2] and got.skipped == c[3],
      "round trip failed for " .. text .. ": got " ..
      got.passed .. "/" .. got.failed .. "/" .. got.skipped)
  end
  local none = records.parse_counts("nothing to see here")
  assert(none == nil, "text with no counts line reports nil, not 0 (#992: was -1)")
end
test_counts_round_trips()

-- The verdict detail says how much FAILED, not how much there was.
local function test_detail_says_what_went_wrong()
  assert(records.detail(0, 19, "file") == "19 files", "all clear: the size")
  assert(records.detail(1, 19, "file") == "1 of 19 files", "one bad: which")
  assert(records.detail(0, 1, "file") == "1 file", "singular")
end
test_detail_says_what_went_wrong()

-- A verb's verdict is a claim about the stage that just ran, and the
-- only thing that counted that stage is the summary it wrote.
local function test_stage_detail_reads_the_summary()
  local summary = "✓ a\n\n" .. records.counts(1, 1, 0) .. "\n"
  assert(records.stage_detail(summary, 7, "file") == "1 of 2 files",
    "the counts come from the summary, not from the file list's size")

  -- A stage that failed before writing one has no per-target counts.
  -- Inventing them would be worse than saying how big the stage was.
  assert(records.stage_detail(nil, 7, "file") == "7 files",
    "no summary falls back to the size, without claiming a failure count")
end
test_stage_detail_reads_the_summary()

-- The verdict's two halves: `format_verdict` renders the line and
-- `exit_code` reports the status. The format and the code are
-- separate claims, so a caller can use either without the other.
local function test_verdict_halves()
  assert(records.format_verdict("test", true, "19 files") ==
    "test: PASS (19 files)", "PASS with detail")
  assert(records.format_verdict("ci", false, "fmt lint") ==
    "ci: FAIL (fmt lint)", "FAIL names the stages")
  assert(records.format_verdict("clean", true, "") ==
    "clean: PASS", "empty detail drops the parenthetical")
  assert(records.exit_code(true) == 0, "PASS exits 0")
  assert(records.exit_code(false) == 1, "FAIL exits 1")
end
test_verdict_halves()

-- `cosmic.check` may not require this internal tree, so it defines
-- its own EXIT_SKIP; the two are one contract and must agree.
local function test_exit_skip_agrees_with_check()
  local check = require("cosmic.check")
  assert(records.EXIT_SKIP == check.EXIT_SKIP,
    "records.EXIT_SKIP and check.EXIT_SKIP drifted apart")
end
test_exit_skip_agrees_with_check()

-- Exit codes are the same three everywhere, and a skip is not a pass.
local function test_status_is_one_contract()
  assert(records.status_of(records.EXIT_OK) == "pass", "0 passes")
  assert(records.status_of(records.EXIT_SKIP) == "skip", "2 skips")
  assert(records.status_of(1) == "fail", "1 fails")
  assert(records.status_of(137) == "fail", "and so does a signal")
end
test_status_is_one_contract()

print("all records tests passed")
