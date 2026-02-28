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

-- A clean file: short lines, columns within limit, test called right after definition
local function test_check_style_valid()
  local input = write_temp("style_valid.tl", [[
local function test_foo()
  assert(1 == 1)
end
test_foo()
]])
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should succeed on valid file")
end
test_check_style_valid()

-- File with a line exceeding 90 columns
local function test_check_style_wide_column()
  local wide_line = string.rep("x", 91)
  local input = write_temp("style_wide.tl", wide_line .. "\n")
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file with column > 90")
end
test_check_style_wide_column()

-- File with a test function not called after its definition
local function test_check_style_test_ordering()
  local input = write_temp("style_ordering.tl", [[
local function test_bar()
  assert(true)
end
]])
  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail when test not called after definition")
end
test_check_style_test_ordering()

print("All check-style tests passed!")
