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

local function test_check_line_width_under()
  -- line of exactly 90 chars: no diagnostic
  local line = string.rep("a", 90)
  local diags = lint.check_line_width("test.tl", {line}, 90)
  assert(#diags == 0, "expected no diagnostic for line at limit")
end
test_check_line_width_under()

local function test_check_line_width_over()
  -- line of 91 chars: diagnostic
  local line = string.rep("a", 91)
  local diags = lint.check_line_width("test.tl", {line}, 90)
  assert(#diags == 1, "expected diagnostic for line over limit")
  assert(diags[1].rule == "col-limit", "expected col-limit rule, got: " .. tostring(diags[1].rule))
  assert(diags[1].line == 1, "expected line 1")
  assert(diags[1].col == 91, "expected col 91")
end
test_check_line_width_over()

local function test_check_line_width_multiple()
  -- two long lines, one ok
  local lines = {
    string.rep("b", 100),
    string.rep("c", 50),
    string.rep("d", 95),
  }
  local diags = lint.check_line_width("test.tl", lines, 90)
  assert(#diags == 2, "expected 2 diagnostics, got: " .. tostring(#diags))
  assert(diags[1].line == 1, "expected first violation on line 1")
  assert(diags[2].line == 3, "expected second violation on line 3")
end
test_check_line_width_multiple()

local function test_check_assert_order_ok()
  -- function followed immediately by its call
  local lines = {
    "local function test_foo()",
    "  assert(true)",
    "end",
    "test_foo()",
  }
  local diags = lint.check_assert_order("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic when call follows immediately")
end
test_check_assert_order_ok()

local function test_check_assert_order_with_blank()
  -- blank line between end and call: still ok (blank lines are skipped)
  local lines = {
    "local function test_bar()",
    "  assert(true)",
    "end",
    "",
    "test_bar()",
  }
  local diags = lint.check_assert_order("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic when only blank lines between end and call")
end
test_check_assert_order_with_blank()

local function test_check_assert_order_missing_call()
  -- function defined but next non-blank line is not the call
  local lines = {
    "local function test_baz()",
    "  assert(true)",
    "end",
    "local x = 1",
  }
  local diags = lint.check_assert_order("test.tl", lines)
  assert(#diags == 1, "expected diagnostic when call is missing, got: " .. tostring(#diags))
  assert(diags[1].rule == "assert-order", "expected assert-order rule")
  assert(diags[1].line == 1, "expected violation on line 1")
end
test_check_assert_order_missing_call()

local function test_check_assert_order_no_call_at_eof()
  -- function at end of file with no call
  local lines = {
    "local function test_eof()",
    "  assert(true)",
    "end",
  }
  local diags = lint.check_assert_order("test.tl", lines)
  assert(#diags == 1, "expected diagnostic when no call follows at eof")
  assert(diags[1].rule == "assert-order", "expected assert-order rule")
end
test_check_assert_order_no_call_at_eof()

local function test_lint_file_all_rules()
  -- file with: >500 lines, a long line, and a test function not called
  local path = fs.join(tmpdir, "all_rules.tl")
  local lines: {string} = {}
  -- first line: long line (>90 chars)
  lines[#lines + 1] = "-- " .. string.rep("x", 100)
  -- test function without call
  lines[#lines + 1] = "local function test_missing()"
  lines[#lines + 1] = "  assert(true)"
  lines[#lines + 1] = "end"
  lines[#lines + 1] = "local z = 1"
  -- pad to 502 lines to exceed file-length limit
  for i = 6, 502 do
    lines[#lines + 1] = "-- pad " .. tostring(i)
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  -- expect file-length + col-limit + assert-order
  assert(#diagnostics >= 3, "expected at least 3 diagnostics, got: " .. tostring(#diagnostics))
  local rules: {string: boolean} = {}
  for _, d in ipairs(diagnostics) do
    rules[d.rule] = true
  end
  assert(rules["file-length"], "expected file-length diagnostic")
  assert(rules["col-limit"], "expected col-limit diagnostic")
  assert(rules["assert-order"], "expected assert-order diagnostic")
end
test_lint_file_all_rules()
