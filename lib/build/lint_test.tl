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

local function test_default_column_width()
  assert(lint.DEFAULT_COLUMN_WIDTH == 90, "expected default column width to be 90")
end
test_default_column_width()

local function test_check_column_length_under()
  local lines = {"short line"}
  local diags = lint.check_column_length("test.tl", lines, 90)
  assert(#diags == 0, "expected no diagnostic for line under limit")
end
test_check_column_length_under()

local function test_check_column_length_at_limit()
  local line = string.rep("x", 90)
  local diags = lint.check_column_length("test.tl", {line}, 90)
  assert(#diags == 0, "expected no diagnostic for line at limit")
end
test_check_column_length_at_limit()

local function test_check_column_length_over()
  local line = string.rep("x", 91)
  local diags = lint.check_column_length("test.tl", {line}, 90)
  assert(#diags == 1, "expected diagnostic for line over limit")
  assert(diags[1].rule == "column-length", "expected column-length rule")
  assert(diags[1].col == 91, "expected col to be limit+1")
  assert(diags[1].line == 1, "expected line number 1")
end
test_check_column_length_over()

local function test_check_call_after_define_ok()
  local lines = {
    "local function foo()",
    "  return 1",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic when assert called right after definition")
end
test_check_call_after_define_ok()

local function test_check_call_after_define_missing_call()
  -- foo() is followed by bar definition (not foo call): diagnostic for foo
  -- bar() is followed by foo() call (not bar call): diagnostic for bar
  -- both functions have out-of-order asserts
  local lines = {
    "local function foo()",
    "  return 1",
    "end",
    "local function bar()",
    "  return 2",
    "end",
    "foo()",
    "bar()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 2, "expected 2 diagnostics when asserts not called right after definition, got: " .. tostring(#diags))
  assert(diags[1].rule == "call-after-define", "expected call-after-define rule")
  assert(diags[2].rule == "call-after-define", "expected call-after-define rule")
end
test_check_call_after_define_missing_call()

local function test_count_lines_directory()
  -- count_lines should return 0 for a directory (or symlink to directory) without crashing
  local n = lint.count_lines(tmpdir)
  assert(n == 0, "expected 0 for directory path, got: " .. tostring(n))
end
test_count_lines_directory()

local function test_check_call_after_define_do_block()
  -- A function body with a standalone do...end block must not confuse the closer detection.
  -- Previously, the `end` for the `do` block decremented depth below 1, causing
  -- the function body to appear to close early.
  local lines = {
    "local function foo()",
    "  do",
    "    local x = 1",
    "  end",
    "  return 2",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for function with do...end block, got: " .. tostring(#diags))
end
test_check_call_after_define_do_block()

local function test_check_call_after_define_for_loop()
  -- A function body with a for loop must not confuse the closer detection.
  local lines = {
    "local function foo()",
    "  for i = 1, 10 do",
    "    local x = i",
    "  end",
    "  return 1",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for function with for loop, got: " .. tostring(#diags))
end
test_check_call_after_define_for_loop()

local function test_check_call_after_define_if_block()
  -- A function body with an if...end block must not confuse the closer detection.
  local lines = {
    "local function foo()",
    "  if true then",
    "    return 1",
    "  end",
    "  return 2",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for function with if block, got: " .. tostring(#diags))
end
test_check_call_after_define_if_block()

local function test_check_call_after_define_repeat_until()
  -- A function body with a repeat...until must not confuse the closer detection.
  local lines = {
    "local function foo()",
    "  local x = 0",
    "  repeat",
    "    x = x + 1",
    "  until x >= 3",
    "  return x",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for function with repeat...until, got: " .. tostring(#diags))
end
test_check_call_after_define_repeat_until()

local function test_check_call_after_define_one_line_if()
  -- One-line if/end must net to zero depth change.
  local lines = {
    "local function foo()",
    "  if true then return 1 end",
    "  return 2",
    "end",
    "foo()",
  }
  local diags = lint.check_call_after_define("test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for function with one-line if, got: " .. tostring(#diags))
end
test_check_call_after_define_one_line_if()

local function test_check_cosmo_require_non_test_ignored()
  -- Non-test files are not subject to the cosmo-require rule
  local lines = {'local cosmo = require("cosmo")'}
  local diags = lint.check_cosmo_require("lib/cosmic/init.tl", lines)
  assert(#diags == 0, "expected no diagnostic for non-test file")
end
test_check_cosmo_require_non_test_ignored()

local function test_check_cosmo_require_in_test_flagged()
  local lines = {'local cosmo = require("cosmo.unix")'}
  local diags = lint.check_cosmo_require("lib/cosmic/foo_test.tl", lines)
  assert(
    #diags == 1,
    "expected 1 diagnostic for test file with require(\"cosmo\"), got: " .. tostring(#diags)
  )
  assert(diags[1].rule == "cosmo-require", "expected cosmo-require rule, got: " .. tostring(diags[1].rule))
end
test_check_cosmo_require_in_test_flagged()

local function test_check_cosmo_require_in_example_flagged()
  local lines = {'local cosmo = require("cosmo")'}
  local diags = lint.check_cosmo_require("lib/cosmic/foo_example.tl", lines)
  assert(#diags == 1, "expected 1 diagnostic for example file with require(\"cosmo\")")
  assert(diags[1].rule == "cosmo-require", "expected cosmo-require rule")
end
test_check_cosmo_require_in_example_flagged()

local function test_check_cosmo_require_allowlisted()
  local lines = {'local cosmo = require("cosmo.unix")'}
  local diags = lint.check_cosmo_require("lib/cosmic/fs_test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for allowlisted file")
end
test_check_cosmo_require_allowlisted()

local function test_check_cosmo_require_allowlisted_with_prefix()
  -- Paths with leading ./ prefix should also match allowlist
  local lines = {'local cosmo = require("cosmo.unix")'}
  local diags = lint.check_cosmo_require("./lib/cosmic/child_test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for allowlisted file with ./ prefix")
end
test_check_cosmo_require_allowlisted_with_prefix()

local function test_check_cosmo_require_in_long_string_skipped()
  -- require("cosmo") inside a [[...]] heredoc must not be flagged
  local lines = {
    'local s = [[',
    '  local cosmo = require("cosmo")',
    ']]',
  }
  local diags = lint.check_cosmo_require("lib/cosmic/foo_test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for cosmo inside heredoc long string")
end
test_check_cosmo_require_in_long_string_skipped()

local function test_check_cosmo_require_plain_test_no_cosmo()
  -- Test file without any cosmo require should produce no diagnostic
  local lines = {
    'local fs = require("cosmic.fs")',
    'local function test_foo()',
    '  assert(true)',
    'end',
    'test_foo()',
  }
  local diags = lint.check_cosmo_require("lib/cosmic/foo_test.tl", lines)
  assert(#diags == 0, "expected no diagnostic for test file with no cosmo require")
end
test_check_cosmo_require_plain_test_no_cosmo()
