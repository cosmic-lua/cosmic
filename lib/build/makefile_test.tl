#!/usr/bin/env cosmic
-- Test the actual repo Makefile using pre-generated make outputs

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_DIR = os.getenv("TEST_DIR")

local record MakeOutput
  output: string
  exit_code: number
end

local function read_make_output(filename: string): MakeOutput
  local filepath = fs.join(TEST_DIR, filename)
  local text = check.must(fs.read(filepath), "failed to read " .. filepath)

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

-- test: only= filters test targets but never artifact source lists (#608).
-- A filter matching nothing must leave the doc-index inputs complete —
-- a filtered doc_index_srcs regenerates o/docs/.index.lua from a subset
-- and the broken index gets embedded in the binary.
local function test_only_filter_exempts_artifact_sources()
  local result = read_make_output("only-database.out")
  local out = result.output

  local doc_srcs = out:match("\ndoc_index_srcs := ([^\n]*)")
  assert(doc_srcs, "expected doc_index_srcs in filtered database output")
  assert(doc_srcs:find("lib/cosmic/json.tl", 1, true),
    "doc_index_srcs should keep module sources under only=")
  assert(doc_srcs:find("lib/cosmic/env_example.tl", 1, true),
    "doc_index_srcs should keep example sources under only=")
  assert(doc_srcs:find("lib/types/cosmo/unix.d.tl", 1, true),
    "doc_index_srcs should keep .d.tl sources under only=")

  local module_srcs = out:match("\nall_module_srcs := ([^\n]*)")
  assert(module_srcs, "expected all_module_srcs in filtered database output")
  assert(module_srcs:find("lib/cosmic/json.tl", 1, true),
    "all_module_srcs (docs inputs) should be exempt from only=")

  -- the filter itself must still work: test lists empty out
  local tests = out:match("\nall_tests := ([^\n]*)")
  assert(tests, "expected all_tests in filtered database output")
  assert(not tests:find("_test.tl", 1, true),
    "all_tests should be empty under a non-matching only=, got: " ..
    tests:sub(1, 200))
end
test_only_filter_exempts_artifact_sources()
