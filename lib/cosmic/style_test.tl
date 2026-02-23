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

-- Test that --check-style passes on a clean file.
local function test_style_clean_file()
  local input = write_temp("clean.tl", [[
local x: number = 42
local y: string = "hello"
print(x, y)
]])
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should pass on clean file, got: " .. tostring(out))
end
test_style_clean_file()

-- Test that --check-style detects a line over 90 columns.
local function test_style_col_limit()
  local long_line = string.rep("x", 91)
  local input = write_temp("col_limit.tl", "local x = 1\n" .. long_line .. "\n")
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on col-limit violation")
  local err_output = out as string
  assert(err_output:find("col%-limit"),
    "should report col-limit rule, got: " .. err_output)
end
test_style_col_limit()

-- Test that --check-style detects a file over 500 lines.
local function test_style_file_length()
  local lines: {string} = {}
  for i = 1, 501 do
    lines[i] = "-- line " .. i
  end
  local input = write_temp("long_file.tl", table.concat(lines, "\n") .. "\n")
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail on file-length violation")
  local err_output = out as string
  assert(err_output:find("file%-length"),
    "should report file-length rule, got: " .. err_output)
end
test_style_file_length()

-- Test that --check-style detects a test function not called.
-- Build content as a string (not [[...]] to avoid pattern matches on raw lines).
local function test_style_test_not_called()
  local content = "local function test_foo()\n"
  .. "  assert(true)\n"
  .. "end\n"
  .. "\n"
  .. "local function test_bar()\n"
  .. "  assert(true)\n"
  .. "end\n"
  .. "test_bar()\n"
  local input = write_temp("missing_call_test.tl", content)
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail when test function not called")
  local err_output = out as string
  assert(err_output:find("test%-not%-called"),
    "should report test-not-called rule, got: " .. err_output)
end
test_style_test_not_called()

-- Test that --check-style detects a test function called out of order.
-- Build content as a string to avoid tripping the checker on raw lines.
local function test_style_test_order()
  local content = "local function test_alpha()\n"
  .. "  assert(true)\n"
  .. "end\n"
  .. "\n"
  .. "local function test_beta()\n"
  .. "  assert(true)\n"
  .. "end\n"
  .. "test_alpha()\n"
  .. "test_beta()\n"
  local input = write_temp("out_of_order_test.tl", content)
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(not ok, "cosmic --check-style should fail when test called out of order")
  local err_output = out as string
  assert(
    err_output:find("test%-order") or err_output:find("test%-not%-called"),
    "should report test-order or test-not-called, got: " .. err_output
  )
end
test_style_test_order()

-- Test that --check-style passes on a clean _test.tl file.
local function test_style_clean_test_file()
  local content = "local function test_good()\n"
  .. "  assert(1 == 1)\n"
  .. "end\n"
  .. "test_good()\n"
  .. "\n"
  .. "local function test_also_good()\n"
  .. "  assert(2 == 2)\n"
  .. "end\n"
  .. "test_also_good()\n"
  local input = write_temp("clean_test.tl", content)
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok,
    "cosmic --check-style should pass on clean test file, got: " .. tostring(out))
end
test_style_clean_test_file()

-- Test that --check-style skips .d.tl files.
local function test_style_skips_dtl()
  -- Write a .d.tl file that would fail col-limit if checked.
  local long_line = string.rep("x", 200)
  local input = write_temp("types.d.tl", long_line .. "\n")
  local ok, out = spawn.spawn({cosmic, "--check-style", input}):read()
  assert(ok, "cosmic --check-style should skip .d.tl files, got: " .. tostring(out))
end
test_style_skips_dtl()

-- Test that the --check-style flag appears in help text.
local function test_style_in_help()
  local ok, out = spawn.spawn({cosmic, "--help"}):read()
  assert(ok, "cosmic --help should succeed")
  local help_text = out as string
  assert(help_text:find("%-%-check%-style"), "--check-style should appear in help")
end
test_style_in_help()

print("All style tests passed!")
