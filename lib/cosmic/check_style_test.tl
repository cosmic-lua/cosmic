#!/usr/bin/env cosmic
-- test cosmic --check-style option

local path = require("cosmo.path")
local cosmo = require("cosmo")
local spawn = require("cosmic.child")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  cosmo.Barf(filepath, content)
  return filepath
end

-- Valid short file with short lines and proper assert ordering passes
local function test_check_style_valid()
  local input = write_temp("style_valid.tl", [[
local function test_ok()
  assert(true)
end
test_ok()
]])
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should succeed on valid file")
end
test_check_style_valid()

-- File with line > 90 columns fails with line-columns rule
local function test_check_style_long_line()
  local long_line = string.rep("x", 91)
  local input = write_temp("style_long_line.tl", long_line .. "\n")
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on line > 90 cols")
end
test_check_style_long_line()

-- File > 500 lines fails with file-length rule
local function test_check_style_long_file()
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  local input = write_temp("style_long_file.tl", table.concat(lines, "\n") .. "\n")
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file > 500 lines")
end
test_check_style_long_file()

-- File with test function not called immediately after definition fails
local function test_check_style_bad_ordering()
  local input = write_temp("style_bad_order.tl", [[
local function test_broken()
  assert(true)
end
local x = 1
test_broken()
]])
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on bad assert ordering")
end
test_check_style_bad_ordering()

print("All check-style tests passed!")
