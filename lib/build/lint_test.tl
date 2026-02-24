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

local function test_check_line_columns_pass()
  local lines = {"local x = 1"}
  local diags = lint.check_line_columns("test.tl", lines, 90)
  assert(#diags == 0, "expected no diagnostics for short line, got: " .. tostring(#diags))
end
test_check_line_columns_pass()

local function test_check_line_columns_fail()
  local long_line = string.rep("x", 91)
  local diags = lint.check_line_columns("test.tl", {long_line}, 90)
  assert(#diags == 1, "expected 1 diagnostic for long line, got: " .. tostring(#diags))
  assert(diags[1].rule == "line-columns", "expected line-columns rule")
  assert(diags[1].col == 91, "expected col 91, got: " .. tostring(diags[1].col))
  assert(diags[1].line == 1, "expected line 1, got: " .. tostring(diags[1].line))
end
test_check_line_columns_fail()

local function test_check_line_columns_at_limit()
  local line_at_limit = string.rep("x", 90)
  local diags = lint.check_line_columns("test.tl", {line_at_limit}, 90)
  assert(#diags == 0, "expected no diagnostics for line at limit, got: " .. tostring(#diags))
end
test_check_line_columns_at_limit()

local function test_check_assert_ordering_pass()
  local lines = {
    "local function test_foo()",
    "  assert(true)",
    "end",
    "test_foo()",
  }
  local diags = lint.check_assert_ordering("test.tl", lines)
  assert(#diags == 0, "expected no diagnostics for ordered assert, got: " .. tostring(#diags))
end
test_check_assert_ordering_pass()

local function test_check_assert_ordering_fail()
  local lines = {
    "local function test_foo()",
    "  assert(true)",
    "end",
    "",
    "local x = 1",
    "test_foo()",
  }
  local diags = lint.check_assert_ordering("test.tl", lines)
  assert(#diags == 1, "expected 1 diagnostic for unordered assert, got: " .. tostring(#diags))
  assert(diags[1].rule == "assert-ordering", "expected assert-ordering rule")
end
test_check_assert_ordering_fail()

local function test_check_assert_ordering_blank_lines_between()
  -- blank lines between end and call are skipped — still valid
  local lines = {
    "local function test_bar()",
    "  assert(true)",
    "end",
    "",
    "test_bar()",
  }
  local diags = lint.check_assert_ordering("test.tl", lines)
  assert(#diags == 0, "expected no diagnostics when blank line between end and call, got: " .. tostring(#diags))
end
test_check_assert_ordering_blank_lines_between()

local function test_check_style_pass()
  local path = fs.join(tmpdir, "style_pass.tl")
  cio.barf(path, "local x = 1\n")
  local diags = lint.check_style(path)
  assert(#diags == 0, "expected no diagnostics for clean file, got: " .. tostring(#diags))
end
test_check_style_pass()

local function test_check_style_column_fail()
  local path = fs.join(tmpdir, "style_col.tl")
  cio.barf(path, string.rep("x", 91) .. "\n")
  local diags = lint.check_style(path)
  assert(#diags == 1, "expected 1 diagnostic for long column, got: " .. tostring(#diags))
  assert(diags[1].rule == "line-columns", "expected line-columns rule")
end
test_check_style_column_fail()

local function test_default_col_limit()
  assert(lint.DEFAULT_COL_LIMIT == 90, "expected DEFAULT_COL_LIMIT to be 90")
end
test_default_col_limit()
