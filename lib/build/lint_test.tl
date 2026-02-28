#!/usr/bin/env cosmic

local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local lint = require("build.lint")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_count_lines()
  local path = fs.join(tmpdir, "count_lines.txt")
  cio.barf(path, "one\ntwo\nthree\n")
  local n = lint.count_lines(path)
  assert(n == 3, "expected 3 lines, got: " .. tostring(n))
end
test_count_lines()

local function test_count_lines_empty()
  local path = fs.join(tmpdir, "empty.txt")
  cio.barf(path, "")
  local n = lint.count_lines(path)
  assert(n == 0, "expected 0 lines, got: " .. tostring(n))
end
test_count_lines_empty()

local function test_count_lines_missing()
  local n = lint.count_lines(fs.join(tmpdir, "nonexistent.txt"))
  assert(n == 0, "expected 0 for missing file")
end
test_count_lines_missing()

local function test_check_file_length_under()
  local diags = lint.check_file_length("test.tl", 100, 500)
  assert(#diags == 0, "expected no diagnostic for file under limit")
end
test_check_file_length_under()

local function test_check_file_length_at_limit()
  local diags = lint.check_file_length("test.tl", 500, 500)
  assert(#diags == 0, "expected no diagnostic for file at limit")
end
test_check_file_length_at_limit()

local function test_check_file_length_over()
  local diags = lint.check_file_length("test.tl", 501, 500)
  assert(#diags == 1, "expected diagnostic for file over limit")
  assert(diags[1].rule == "file-length", "expected file-length rule")
  assert(diags[1].file == "test.tl", "expected file name")
  assert(diags[1].message:match("501"), "expected line count in message")
  assert(diags[1].message:match("500"), "expected limit in message")
end
test_check_file_length_over()

local function test_lint_file_under_default()
  local path = fs.join(tmpdir, "short.tl")
  local lines: {string} = {}
  for i = 1, 100 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  assert(#diagnostics == 0, "expected no diagnostics for short file, got: " .. tostring(#diagnostics))
end
test_lint_file_under_default()

local function test_lint_file_over_default()
  local path = fs.join(tmpdir, "long.tl")
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  assert(#diagnostics == 1, "expected 1 diagnostic for long file, got: " .. tostring(#diagnostics))
  assert(diagnostics[1].rule == "file-length", "expected file-length rule")
end
test_lint_file_over_default()

local function test_lint_file_skips_dtl()
  -- .d.tl files are type declarations for C bindings and are exempt from length checks
  local path = fs.join(tmpdir, "types.d.tl")
  local lines: {string} = {}
  for i = 1, 600 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  assert(#diagnostics == 0, "expected no diagnostics for .d.tl file, got: " .. tostring(#diagnostics))
end
test_lint_file_skips_dtl()

local function test_default_file_lines()
  assert(lint.DEFAULT_FILE_LINES == 500, "expected default to be 500")
end
test_default_file_lines()

local function test_count_lines_directory()
  -- count_lines should return 0 for a directory (or symlink to directory) without crashing
  local n = lint.count_lines(tmpdir)
  assert(n == 0, "expected 0 for directory path, got: " .. tostring(n))
end
test_count_lines_directory()
