--- Examples for the _tool.records module.
--- A build writes four things for something other than a person to
--- read: a per-target row, a stage summary, a verb's verdict, and the
--- exit code each maps to. This module is where that grammar lives, so
--- a printer and a test can never disagree about it.

-- Example_row shows what a result row says. The name is the SOURCE the
-- result is about, so two `init_test.tl` in different packages are two
-- different rows; the annotation counts what the target actually ran,
-- so it appears only on a status that ran something.
local function Example_row()
  local records = require("_tool.records")
  print(records.row("pass", "cosmic/fs/init_test.tl", 7, "test functions", 12))
  print(records.row("skip", "cosmic/net_test.tl", 7, "test functions", 3))
  print(records.row("fail", "cosmic/json_test.tl", 0, "test functions", 41))
  -- Output:
  -- ✓ cosmic/fs/init_test.tl (7 test functions)  12ms
  -- → cosmic/net_test.tl  3ms
  -- ✗ cosmic/json_test.tl  41ms
end

-- Example_display turns a `.got` base path into that name. The build
-- directory mirrors the source tree, so dropping `o/` and the stage
-- suffix leaves the path you typed -- and the path an editor opens.
local function Example_display()
  local records = require("_tool.records")
  print(records.display("o/cosmic/fs/init_test.tl.test"))
  print(records.display("o/cosmic/child/init_test.tl.test"))
  print(records.stage_of("o/cosmic/fs/init_test.tl.test"))
  -- Output:
  -- cosmic/fs/init_test.tl
  -- cosmic/child/init_test.tl
  -- test
end

-- Example_summary_round_trip shows why the counts line and its parser
-- live together: the summary a stage WRITES is the summary its verb
-- READS BACK to decide what its verdict says.
local function Example_summary_round_trip()
  local records = require("_tool.records")
  local line = records.counts(17, 1, 1)
  print(line)
  local passed, failed, skipped = records.parse_counts(line)
  print(passed, failed, skipped)
  -- Output:
  -- 19 checks: 17 passed, 1 failed, 1 skipped
  -- 17	1	1
end

-- Example_detail shows the verdict's parenthetical. It says how much
-- FAILED, not how much there was: the verdict line is the record that
-- survives a truncated log, so its number has to be the one worth
-- keeping.
local function Example_detail()
  local records = require("_tool.records")
  print(records.detail(0, 19, "file"))
  print(records.detail(1, 19, "file"))
  print(records.detail(0, 1, "file"))
  -- Output:
  -- 19 files
  -- 1 of 19 files
  -- 1 file
end

-- Example_status shows the one exit-code contract every stage reports
-- through. A skip is NOT a pass -- a stage that stopped checking and
-- said nothing is exactly what the third code exists to make visible.
local function Example_status()
  local records = require("_tool.records")
  print(records.status_of(0))
  print(records.status_of(2))
  print(records.status_of(1))
  -- Output:
  -- pass
  -- skip
  -- fail
end

return {
  Example_row = Example_row,
  Example_display = Example_display,
  Example_summary_round_trip = Example_summary_round_trip,
  Example_detail = Example_detail,
  Example_status = Example_status,
}
