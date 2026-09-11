#!/usr/bin/env cosmic
--- Tests for compact uncovered-line ranges.
local gaps = require("_tool.coverage.gaps")

local function test_one_line()
  assert(gaps.format_ranges({4}, 8) == "4")
end

local function test_one_run()
  assert(gaps.format_ranges({3, 4, 5}, 8) == "3-5")
end

local function test_mixed_runs()
  assert(gaps.format_ranges({1, 3, 4, 8, 9, 10}, 8) == "1,3-4,8-10")
end

local function test_no_gaps()
  assert(gaps.format_ranges({}, 8) == "")
end

local function test_truncation()
  assert(gaps.format_ranges({1, 3, 5, 7, 9}, 2) == "1,3 +3 more")
end

print("all coverage gaps tests passed")
