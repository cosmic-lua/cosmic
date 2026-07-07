#!/usr/bin/env cosmic
-- Test the actual repo Makefile using pre-generated make outputs

local fs = require("cosmic.fs")

local TEST_DIR = os.getenv("TEST_DIR")

local record MakeOutput
  output: string
  exit_code: number
end

local function read_make_output(filename: string): MakeOutput
  local filepath = fs.join(TEST_DIR, filename)
  local content = fs.read(filepath)
  assert(content, "failed to read " .. filepath)
  local text = content as string

  local exit_code = text:match("exit:(%d+)%s*$")
  assert(exit_code, "missing exit code in " .. filepath)

  local output = text:gsub("exit:%d+%s*$", "")
  return {
    output = output,
    exit_code = tonumber(exit_code),
  }
end

-- test: make -n files succeeds (validates syntax and prerequisites)
local function test_dry_run_succeeds()
  local result = read_make_output("dry-run.out")
  assert(result.exit_code == 0,
    "expected make -n files to succeed, got code: " .. tostring(result.exit_code) ..
    "\noutput: " .. result.output:sub(1, 500))
end
test_dry_run_succeeds()

-- test: make -p prints database with expected content
local function test_print_database()
  local result = read_make_output("database.out")
  assert(result.output:match("modules"), "expected 'modules' variable in database output")
  assert(result.output:match("%.PHONY"), "expected .PHONY in database output")
  assert(result.output:match("platform"), "expected 'platform' variable in database output")
end
test_print_database()
