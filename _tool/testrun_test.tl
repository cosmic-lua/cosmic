#!/usr/bin/env cosmic
local testrun = require("_tool.testrun")
local fs = require("cosmic.fs")

local TEST_BIN = os.getenv("TEST_BIN")
local TEST_TMPDIR = os.getenv("TEST_TMPDIR")
local cosmic_bin = fs.join(TEST_BIN, "cosmic")

-- Test running cosmic with a script
local function test_run_cosmic_script()
  local script = fs.join(TEST_TMPDIR, "test_script.lua")
  local output_base = fs.join(TEST_TMPDIR, "result_script")

  assert(fs.write(script, [[print("hello from script")]]))

  local exit_code = testrun.run({cosmic_bin, script}, output_base)
  assert(exit_code == 0, "expected exit code 0, got " .. exit_code)

  local out = fs.read(output_base .. ".out")
  assert(out == "hello from script\n", "expected script output, got '" .. (out or "nil") .. "'")
end
test_run_cosmic_script()

-- Test run with nested output directory
local function test_run_creates_parent_dirs()
  local output_base = fs.join(TEST_TMPDIR, "nested", "dir", "result")

  local exit_code = testrun.run({"/bin/true"}, output_base)
  assert(exit_code == 0, "expected exit code 0, got " .. exit_code)

  -- Check files exist
  local got = fs.read(output_base .. ".got")
  assert(got == "0\n", "expected .got to contain '0\\n', got '" .. (got or "nil") .. "'")

  local out = fs.read(output_base .. ".out")
  assert(out ~= nil, "expected .out file to exist")

  local err = fs.read(output_base .. ".err")
  assert(err ~= nil, "expected .err file to exist")

  -- Cleanup
  assert(fs.remove_all(fs.join(TEST_TMPDIR, "nested")))
end
test_run_creates_parent_dirs()

-- Test run with executable that writes to stdout/stderr
local function test_run_captures_output()
  local script = fs.join(TEST_TMPDIR, "test_output.sh")
  local output_base = fs.join(TEST_TMPDIR, "result_output")

  assert(fs.write(script, [[#!/bin/sh
echo "stdout line"
echo "stderr line" >&2
exit 0
]], {mode = tonumber("755", 8)}))

  local exit_code = testrun.run({script}, output_base)
  assert(exit_code == 0, "expected exit code 0, got " .. exit_code)

  local got = fs.read(output_base .. ".got")
  assert(got == "0\n", "expected .got to contain '0\\n', got '" .. (got or "nil") .. "'")

  local out = fs.read(output_base .. ".out")
  assert(out == "stdout line\n", "expected .out to contain 'stdout line\\n', got '" .. (out or "nil") .. "'")

  local err = fs.read(output_base .. ".err")
  assert(err == "stderr line\n", "expected .err to contain 'stderr line\\n', got '" .. (err or "nil") .. "'")
end
test_run_captures_output()

-- Test that TEST_TMPDIR is set and is a directory
local function test_run_sets_test_tmpdir()
  local script = fs.join(TEST_TMPDIR, "test_tmpdir.sh")
  local output_base = fs.join(TEST_TMPDIR, "result_tmpdir")

  -- Script checks TEST_TMPDIR exists and is a directory
  assert(fs.write(script, [[#!/bin/sh
if [ -z "$TEST_TMPDIR" ]; then
  echo "TEST_TMPDIR not set" >&2
  exit 1
fi
if [ ! -d "$TEST_TMPDIR" ]; then
  echo "TEST_TMPDIR is not a directory: $TEST_TMPDIR" >&2
  exit 1
fi
# Create a file to prove we can write to it
echo "test" > "$TEST_TMPDIR/test_file"
if [ ! -f "$TEST_TMPDIR/test_file" ]; then
  echo "Failed to create file in TEST_TMPDIR" >&2
  exit 1
fi
echo "TEST_TMPDIR works"
exit 0
]], {mode = tonumber("755", 8)}))

  local exit_code = testrun.run({script}, output_base)
  assert(exit_code == 0, "expected exit code 0, got " .. exit_code)

  local out = fs.read(output_base .. ".out")
  assert(out == "TEST_TMPDIR works\n", "expected success message, got '" .. (out or "nil") .. "'")
end
test_run_sets_test_tmpdir()

-- Test run with nonexistent executable
local function test_run_nonexistent()
  local output_base = fs.join(TEST_TMPDIR, "result_nonexistent")

  local exit_code = testrun.run({"/nonexistent/path/to/exe"}, output_base)
  -- Child process exits 127 when execve fails (command not found)
  assert(exit_code == 127, "expected exit code 127 for nonexistent executable, got " .. exit_code)

  -- Check that the .got file was written with the exit code
  local got = fs.read(output_base .. ".got")
  assert(got == "127\n", "expected .got to contain '127\\n', got '" .. (got or "nil") .. "'")
end
test_run_nonexistent()

-- Test report with passing test
local function test_report_pass()
  local base = fs.join(TEST_TMPDIR, "report_pass")

  assert(fs.write(base .. ".got", "0\n"))
  assert(fs.write(base .. ".out", ""))
  assert(fs.write(base .. ".err", ""))

  local exit_code = testrun.report({base})
  assert(exit_code == 0, "expected exit code 0 for passing test, got " .. exit_code)
end
test_report_pass()

-- Test report with failing test
local function test_report_fail()
  local base = fs.join(TEST_TMPDIR, "report_fail")

  assert(fs.write(base .. ".got", "1\n"))
  assert(fs.write(base .. ".out", "stdout output\n"))
  assert(fs.write(base .. ".err", "error output\n"))

  local exit_code = testrun.report({base})
  assert(exit_code == 1, "expected exit code 1 for failing test, got " .. exit_code)
end
test_report_fail()

-- Test report with skipped test
local function test_report_skip()
  local base = fs.join(TEST_TMPDIR, "report_skip")

  assert(fs.write(base .. ".got", "2\n"))
  assert(fs.write(base .. ".out", ""))
  assert(fs.write(base .. ".err", ""))

  local exit_code = testrun.report({base})
  assert(exit_code == 0, "expected exit code 0 for skipped test, got " .. exit_code)
end
test_report_skip()

-- Test report with multiple tests
local function test_report_multiple()
  local base1 = fs.join(TEST_TMPDIR, "report_multi_1")
  local base2 = fs.join(TEST_TMPDIR, "report_multi_2")
  local base3 = fs.join(TEST_TMPDIR, "report_multi_3")

  assert(fs.write(base1 .. ".got", "0\n"))
  assert(fs.write(base1 .. ".out", ""))
  assert(fs.write(base1 .. ".err", ""))

  assert(fs.write(base2 .. ".got", "1\n"))
  assert(fs.write(base2 .. ".out", "failed\n"))
  assert(fs.write(base2 .. ".err", "error\n"))

  assert(fs.write(base3 .. ".got", "2\n"))
  assert(fs.write(base3 .. ".out", ""))
  assert(fs.write(base3 .. ".err", ""))

  local exit_code = testrun.report({base1, base2, base3})
  assert(exit_code == 1, "expected exit code 1 when any test fails, got " .. exit_code)
end
test_report_multiple()

-- Test report with .got extension
local function test_report_with_got_extension()
  local base = fs.join(TEST_TMPDIR, "report_ext")

  assert(fs.write(base .. ".got", "0\n"))
  assert(fs.write(base .. ".out", ""))
  assert(fs.write(base .. ".err", ""))

  -- Pass path with .got extension
  local exit_code = testrun.report({base .. ".got"})
  assert(exit_code == 0, "expected exit code 0 when passing .got path, got " .. exit_code)
end
test_report_with_got_extension()

-- Test report with missing .got file
local function test_report_missing_got()
  local base = fs.join(TEST_TMPDIR, "report_missing")

  -- Don't create any files
  local exit_code = testrun.report({base})
  assert(exit_code == 1, "expected exit code 1 for missing .got file, got " .. exit_code)
end
test_report_missing_got()

print("testrun tests passed")
