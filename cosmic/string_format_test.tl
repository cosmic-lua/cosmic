#!/usr/bin/env cosmic
local str = require("cosmic.string")
local check = require("cosmic.check")

-- pad_left tests

local function test_pad_left_basic()
  assert(str.pad_left("5", 3) == "  5", "expected '  5'")
  assert(str.pad_left("5", 3, "0") == "005", "expected '005'")
end
test_pad_left_basic()

local function test_pad_left_already_wide()
  assert(str.pad_left("hello", 3) == "hello", "expected unchanged")
  assert(str.pad_left("abc", 3) == "abc", "expected exact width unchanged")
end
test_pad_left_already_wide()

local function test_pad_left_multichar_pad()
  assert(str.pad_left("x", 6, "ab") == "ababax", "expected 'ababax'")
  assert(str.pad_left("x", 4, "abc") == "abcx", "expected 'abcx'")
end
test_pad_left_multichar_pad()

local function test_pad_left_edges()
  assert(str.pad_left("", 3) == "   ", "expected three spaces")
  assert(str.pad_left("x", 0) == "x", "expected zero width unchanged")
  assert(str.pad_left("x", 5, "") == "x", "expected empty pad unchanged")
end
test_pad_left_edges()

-- pad_right tests

local function test_pad_right_basic()
  assert(str.pad_right("5", 3) == "5  ", "expected '5  '")
  assert(str.pad_right("5", 3, "0") == "500", "expected '500'")
end
test_pad_right_basic()

local function test_pad_right_already_wide()
  assert(str.pad_right("hello", 3) == "hello", "expected unchanged")
  assert(str.pad_right("abc", 3) == "abc", "expected exact width unchanged")
end
test_pad_right_already_wide()

local function test_pad_right_multichar_pad()
  assert(str.pad_right("x", 6, "ab") == "xababa", "expected 'xababa'")
  assert(str.pad_right("x", 4, "abc") == "xabc", "expected 'xabc'")
end
test_pad_right_multichar_pad()

local function test_pad_right_edges()
  assert(str.pad_right("", 3) == "   ", "expected three spaces")
  assert(str.pad_right("x", 0) == "x", "expected zero width unchanged")
  assert(str.pad_right("x", 5, "") == "x", "expected empty pad unchanged")
end
test_pad_right_edges()

-- dedent tests

local function test_dedent_basic()
  assert(str.dedent("  a\n  b") == "a\nb", "expected common margin removed")
  assert(str.dedent("    a\n      b") == "a\n  b", "expected relative indent kept")
end
test_dedent_basic()

local function test_dedent_mixed_margins()
  assert(str.dedent("    a\n  b") == "  a\nb", "expected shortest margin removed")
  assert(str.dedent("a\n  b") == "a\n  b", "expected no common margin")
end
test_dedent_mixed_margins()

local function test_dedent_blank_lines_ignored()
  assert(str.dedent("  a\n\n  b") == "a\n\nb", "expected blank line ignored for margin")
  assert(str.dedent("  a\n \n  b") == "a\n \nb", "expected whitespace-only line ignored")
end
test_dedent_blank_lines_ignored()

local function test_dedent_tabs()
  assert(str.dedent("\ta\n\tb") == "a\nb", "expected tab margin removed")
  assert(str.dedent("\ta\n  b") == "\ta\n  b", "expected tab/space mix unchanged")
end
test_dedent_tabs()

local function test_dedent_edges()
  assert(str.dedent("") == "", "expected empty unchanged")
  assert(str.dedent("plain") == "plain", "expected unindented unchanged")
  assert(str.dedent("  only") == "only", "expected single line dedented")
end
test_dedent_edges()

-- indent tests

local function test_indent_basic()
  assert(str.indent("a\nb", "  ") == "  a\n  b", "expected both lines indented")
  assert(str.indent("a", "> ") == "> a", "expected single line indented")
end
test_indent_basic()

local function test_indent_blank_lines_skipped()
  assert(str.indent("a\n\nb", "  ") == "  a\n\n  b", "expected empty line untouched")
  assert(str.indent("a\n \nb", "  ") == "  a\n \n  b", "expected blank line untouched")
end
test_indent_blank_lines_skipped()

local function test_indent_edges()
  assert(str.indent("", "  ") == "", "expected empty unchanged")
  assert(str.indent("a\nb", "") == "a\nb", "expected empty prefix unchanged")
  assert(str.indent("a\nb\n", "  ") == "  a\n  b\n", "expected trailing newline kept")
end
test_indent_edges()

-- truncate tests

local function test_truncate_basic()
  assert(str.truncate("hello world", 8) == "hello...", "expected 'hello...'")
  assert(#str.truncate("hello world", 8) == 8, "expected exact width")
end
test_truncate_basic()

local function test_truncate_no_cut()
  assert(str.truncate("hello", 5) == "hello", "expected exact fit unchanged")
  assert(str.truncate("hi", 10) == "hi", "expected short string unchanged")
end
test_truncate_no_cut()

local function test_truncate_custom_suffix()
  assert(str.truncate("hello world", 6, "~") == "hello~", "expected custom suffix")
  assert(str.truncate("hello world", 5, "") == "hello", "expected bare cut with empty suffix")
end
test_truncate_custom_suffix()

local function test_truncate_tiny_width()
  assert(str.truncate("hello", 3) == "hel", "expected hard cut when suffix does not fit")
  assert(str.truncate("hello", 0) == "", "expected empty at width 0")
end
test_truncate_tiny_width()

-- shell_quote tests

local function test_shell_quote_safe_unchanged()
  assert(str.shell_quote("hello") == "hello", "expected safe word unchanged")
  assert(str.shell_quote("a/b.c-d_e") == "a/b.c-d_e", "expected path unchanged")
  assert(str.shell_quote("K=V,x:y+z@h%1") == "K=V,x:y+z@h%1", "expected safe symbols unchanged")
end
test_shell_quote_safe_unchanged()

local function test_shell_quote_spaces_and_specials()
  assert(str.shell_quote("hello world") == "'hello world'", "expected quoted")
  assert(str.shell_quote("a$b") == "'a$b'", "expected $ quoted")
  assert(str.shell_quote("a;rm -rf") == "'a;rm -rf'", "expected ; quoted")
  assert(str.shell_quote("a\"b") == "'a\"b'", "expected double quote quoted")
  assert(str.shell_quote("a*b") == "'a*b'", "expected glob quoted")
end
test_shell_quote_spaces_and_specials()

local function test_shell_quote_single_quotes()
  assert(str.shell_quote("it's") == "'it'\\''s'", "expected embedded quote escaped")
  assert(str.shell_quote("'") == "''\\'''", "expected lone quote escaped")
end
test_shell_quote_single_quotes()

local function test_shell_quote_empty()
  assert(str.shell_quote("") == "''", "expected empty quoted as ''")
end
test_shell_quote_empty()

local function test_shell_quote_roundtrip()
  local child = require("cosmic.child")
  local payload = "it's a $test; with \"quotes\" and *globs*"
  local result = check.must(
    child.run({"/bin/sh", "-c", "printf %s " .. str.shell_quote(payload)}))
  local out = result.stdout
  assert(out == payload, "expected round-trip through sh, got: " .. tostring(out))
end
test_shell_quote_roundtrip()
