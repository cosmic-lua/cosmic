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

local function test_default_line_cols()
  assert(lint.DEFAULT_LINE_COLS == 90, "expected default cols to be 90")
end
test_default_line_cols()

local function test_check_line_columns_under()
  local path = fs.join(tmpdir, "short_cols.tl")
  cio.barf(path, string.rep("a", 90) .. "\n")
  local diags = lint.check_line_columns(path, 90)
  assert(#diags == 0, "expected no diagnostic for line at limit")
end
test_check_line_columns_under()

local function test_check_line_columns_over()
  local path = fs.join(tmpdir, "long_cols.tl")
  cio.barf(path, string.rep("a", 91) .. "\n")
  local diags = lint.check_line_columns(path, 90)
  assert(#diags == 1, "expected 1 diagnostic for line over limit")
  assert(diags[1].rule == "line-columns", "expected line-columns rule")
  assert(diags[1].line == 1, "expected line 1")
  assert(diags[1].col == 91, "expected col 91")
end
test_check_line_columns_over()

local function test_check_line_columns_missing()
  local diags = lint.check_line_columns(fs.join(tmpdir, "nonexistent.tl"), 90)
  assert(#diags == 0, "expected no diagnostic for missing file")
end
test_check_line_columns_missing()

local function test_check_assert_ordering_pass()
  local path = fs.join(tmpdir, "ordered.tl")
  cio.barf(path, [[
local function test_foo()
  assert(true)
end
test_foo()
]])
  local diags = lint.check_assert_ordering(path)
  assert(#diags == 0, "expected no diagnostic for correctly ordered test: " .. tostring(#diags))
end
test_check_assert_ordering_pass()

local function test_check_assert_ordering_fail()
  local path = fs.join(tmpdir, "unordered.tl")
  cio.barf(path, [[
local function test_bar()
  assert(true)
end
local x = 1
test_bar()
]])
  local diags = lint.check_assert_ordering(path)
  assert(#diags == 1, "expected 1 diagnostic for unordered test: " .. tostring(#diags))
  assert(diags[1].rule == "assert-ordering", "expected assert-ordering rule")
end
test_check_assert_ordering_fail()

local function test_check_assert_ordering_blank_lines()
  -- Blank lines between function end and call are OK
  local path = fs.join(tmpdir, "blank_between.tl")
  cio.barf(path, [[
local function test_baz()
  assert(true)
end

test_baz()
]])
  local diags = lint.check_assert_ordering(path)
  assert(#diags == 0, "expected no diagnostic when blank line between def and call")
end
test_check_assert_ordering_blank_lines()

local function test_check_assert_ordering_non_test_fn()
  -- Helper functions (not test_*) are not checked
  local path = fs.join(tmpdir, "helper.tl")
  cio.barf(path, [[
local function write_temp(name: string): string
  return name
end
local x = 1
]])
  local diags = lint.check_assert_ordering(path)
  assert(#diags == 0, "expected no diagnostic for non-test function")
end
test_check_assert_ordering_non_test_fn()

local function test_lint_file_column_violation()
  local path = fs.join(tmpdir, "col_violation.tl")
  local long_line = string.rep("x", 91)
  cio.barf(path, long_line .. "\n")
  local diags = lint.style_file(path)
  local found = false
  for _, d in ipairs(diags) do
    if d.rule == "line-columns" then found = true end
  end
  assert(found, "expected line-columns diagnostic in style_file output")
end
test_lint_file_column_violation()

local function test_lint_file_assert_ordering_violation()
  local path = fs.join(tmpdir, "order_violation.tl")
  cio.barf(path, [[
local function test_thing()
  assert(true)
end
local y = 2
test_thing()
]])
  local diags = lint.style_file(path)
  local found = false
  for _, d in ipairs(diags) do
    if d.rule == "assert-ordering" then found = true end
  end
  assert(found, "expected assert-ordering diagnostic in style_file output")
end
test_lint_file_assert_ordering_violation()
