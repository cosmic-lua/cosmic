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

-- Valid short file: should pass
local function test_style_valid()
  local input = write_temp("style_valid.tl", [[
local function add(a: number, b: number): number
  return a + b
end
add(1, 2)
]])

  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should succeed on valid file")
end
test_style_valid()

-- File with a long line (> 90 cols): should fail
local function test_style_long_line()
  local long_line = string.rep("x", 91)
  local input = write_temp("style_long.tl", long_line .. "\n")

  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file with long line")
end
test_style_long_line()

-- File with function not called immediately after definition: should fail
-- The rule is 'call-after-define': each test_* function must be called right
-- after its definition so failures point to the right function.
local function test_style_call_after_define()
  local input = write_temp("style_order.tl", [[
local function foo()
  return 1
end
local function bar()
  return 2
end
foo()
bar()
]])

  local ok, _ = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail when function not called immediately after definition")
end
test_style_call_after_define()

-- Missing file: should fail
local function test_style_missing_file()
  local ok, _ = spawn.spawn({cosmic, "--check-style", "/nonexistent/file.tl"}):read()
  assert(not ok, "cosmic --check-style should fail on missing file")
end
test_style_missing_file()

print("All style tests passed!")
