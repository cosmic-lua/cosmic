#!/usr/bin/env cosmic
-- test cosmic --check-style option

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  cosmo.Barf(filepath, content)
  return filepath
end

-- Test passes on a clean file
local function test_check_style_clean()
  local input = write_temp("style_clean.tl", "local x = 1\n")
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should succeed on clean file")
end
test_check_style_clean()

-- Test fails on a file exceeding 500 lines
local function test_check_style_too_many_lines()
  local lines: {string} = {}
  for i = 1, 501 do
    lines[#lines + 1] = "-- line " .. tostring(i)
  end
  local input = write_temp("style_long.tl", table.concat(lines, "\n") .. "\n")
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file with >500 lines")
end
test_check_style_too_many_lines()

-- Test fails on a file with a line exceeding 90 columns
local function test_check_style_long_line()
  local long_line = "local x = " .. string.rep("a", 100) .. "\n"
  local input = write_temp("style_longline.tl", long_line)
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file with line >90 cols")
end
test_check_style_long_line()

-- Test fails when test function is not called immediately after definition
local function test_check_style_assert_order_missing()
  local content = [[
local function test_foo()
  assert(true)
end
local x = 1
]]
  local input = write_temp("style_order_missing.tl", content)
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail when test function not called immediately")
end
test_check_style_assert_order_missing()

-- Test passes when test function is called right after definition
local function test_check_style_assert_order_ok()
  local content = [[
local function test_bar()
  assert(true)
end
test_bar()
]]
  local input = write_temp("style_order_ok.tl", content)
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should pass when test function is called immediately after")
end
test_check_style_assert_order_ok()

print("All check-style tests passed!")
