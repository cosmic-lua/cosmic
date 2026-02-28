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

local function test_default_col_limit()
  assert(lint.DEFAULT_COL_LIMIT == 90, "expected default col limit to be 90")
end
test_default_col_limit()

local function test_check_col_length_under()
  local lines = {"local x = 1"}
  local diags = lint.check_col_length("test.tl", lines, 90)
  assert(#diags == 0, "expected no diagnostic for short line")
end
test_check_col_length_under()

local function test_check_col_length_at_limit()
  local line = string.rep("x", 90)
  local diags = lint.check_col_length("test.tl", {line}, 90)
  assert(#diags == 0, "expected no diagnostic for line at limit")
end
test_check_col_length_at_limit()

local function test_check_col_length_over()
  local line = string.rep("x", 91)
  local diags = lint.check_col_length("test.tl", {line}, 90)
  assert(#diags == 1, "expected diagnostic for line over limit")
  assert(diags[1].rule == "col-length", "expected col-length rule")
  assert(diags[1].line == 1, "expected line 1")
  assert(diags[1].col == 91, "expected col 91")
end
test_check_col_length_over()

local function test_check_col_length_multiple()
  local lines = {
    string.rep("a", 91),
    "short",
    string.rep("b", 92),
  }
  local diags = lint.check_col_length("test.tl", lines, 90)
  assert(#diags == 2, "expected 2 diagnostics for two long lines")
end
test_check_col_length_multiple()

local function test_check_assert_test_ordering_ok()
  local source = [[
local function test_foo()
  assert(true)
end
test_foo()
]]
  local diags = lint.check_assert_test_ordering("test.tl", source)
  assert(#diags == 0, "expected no diagnostics for correct ordering")
end
test_check_assert_test_ordering_ok()

local function test_check_assert_test_ordering_missing_call()
  local source = [[
local function test_foo()
  assert(true)
end
]]
  local diags = lint.check_assert_test_ordering("test.tl", source)
  assert(#diags == 1, "expected diagnostic for missing call")
  assert(diags[1].rule == "test-call-order", "expected test-call-order rule")
end
test_check_assert_test_ordering_missing_call()

local function test_check_assert_test_ordering_wrong_call()
  local source = [[
local function test_foo()
  assert(true)
end
test_bar()
]]
  local diags = lint.check_assert_test_ordering("test.tl", source)
  assert(#diags == 1, "expected diagnostic for wrong call after definition")
  assert(diags[1].rule == "test-call-order", "expected test-call-order rule")
end
test_check_assert_test_ordering_wrong_call()

local function test_check_assert_test_ordering_multiple_ok()
  local source = [[
local function test_a()
  assert(1 == 1)
end
test_a()

local function test_b()
  assert(2 == 2)
end
test_b()
]]
  local diags = lint.check_assert_test_ordering("test.tl", source)
  assert(#diags == 0, "expected no diagnostics for two correctly ordered tests")
end
test_check_assert_test_ordering_multiple_ok()

local function test_style_file_clean()
  local path = fs.join(tmpdir, "style_clean.tl")
  cio.barf(path, [[
local function test_ok()
  assert(true)
end
test_ok()
]])
  local diags = lint.style_file(path)
  assert(#diags == 0, "expected no diagnostics for clean style file, got: " .. tostring(#diags))
end
test_style_file_clean()

local function test_style_file_wide_line()
  local path = fs.join(tmpdir, "style_wide.tl")
  cio.barf(path, string.rep("x", 91) .. "\n")
  local diags = lint.style_file(path)
  assert(#diags >= 1, "expected diagnostic for wide line")
  local found = false
  for _, d in ipairs(diags) do
    if d.rule == "col-length" then found = true end
  end
  assert(found, "expected col-length diagnostic")
end
test_style_file_wide_line()

local function test_style_file_missing_test_call()
  local path = fs.join(tmpdir, "style_no_call.tl")
  cio.barf(path, [[
local function test_missing()
  assert(true)
end
]])
  local diags = lint.style_file(path)
  assert(#diags >= 1, "expected diagnostic for missing test call")
  local found = false
  for _, d in ipairs(diags) do
    if d.rule == "test-call-order" then found = true end
  end
  assert(found, "expected test-call-order diagnostic")
end
test_style_file_missing_test_call()
