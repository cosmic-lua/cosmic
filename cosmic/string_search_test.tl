#!/usr/bin/env cosmic
local str = require("cosmic.string")

-- contains tests

local function test_contains_basic()
  assert(str.contains("hello world", "world"), "expected true")
  assert(str.contains("hello", "hello"), "expected true for exact match")
  assert(not str.contains("hello", "xyz"), "expected false")
end
test_contains_basic()

local function test_contains_plain_text()
  assert(str.contains("a.b", "."), "expected literal dot to match")
  assert(not str.contains("axb", "."), "expected no pattern matching")
  assert(str.contains("50%", "%"), "expected literal percent to match")
end
test_contains_plain_text()

local function test_contains_empty()
  assert(str.contains("hello", ""), "expected empty substring contained")
  assert(str.contains("", ""), "expected empty in empty")
  assert(not str.contains("", "a"), "expected false for empty string")
end
test_contains_empty()

-- count tests

local function test_count_basic()
  assert(str.count("banana", "an") == 2, "expected 2")
  assert(str.count("banana", "a") == 3, "expected 3")
  assert(str.count("banana", "x") == 0, "expected 0")
end
test_count_basic()

local function test_count_non_overlapping()
  assert(str.count("aaaa", "aa") == 2, "expected non-overlapping count of 2")
end
test_count_non_overlapping()

local function test_count_plain_text()
  assert(str.count("a.b.c", ".") == 2, "expected literal dots counted")
  assert(str.count("abc", ".") == 0, "expected no pattern matching")
end
test_count_plain_text()

local function test_count_empty()
  assert(str.count("hello", "") == 0, "expected 0 for empty substring")
  assert(str.count("", "a") == 0, "expected 0 for empty string")
end
test_count_empty()

-- replace tests

local function test_replace_basic()
  assert(str.replace("a-b-c", "-", "+") == "a+b+c", "expected all replaced")
  assert(str.replace("hello", "l", "L") == "heLLo", "expected heLLo")
  assert(str.replace("hello", "x", "y") == "hello", "expected unchanged")
end
test_replace_basic()

local function test_replace_plain_text()
  assert(str.replace("a.b.c", ".", "-") == "a-b-c", "expected literal dots replaced")
  assert(str.replace("100%", "%", " pct") == "100 pct", "expected literal percent")
  assert(str.replace("a1b", "1", "%0") == "a%0b", "expected literal replacement text")
end
test_replace_plain_text()

local function test_replace_max()
  assert(str.replace("a-b-c-d", "-", "+", 2) == "a+b+c-d", "expected first 2 replaced")
  assert(str.replace("a-b-c", "-", "+", 0) == "a-b-c", "expected max=0 unchanged")
  assert(str.replace("a-b-c", "-", "+", 99) == "a+b+c", "expected large max ok")
end
test_replace_max()

local function test_replace_multichar_and_growth()
  assert(str.replace("ababab", "ab", "xyz") == "xyzxyzxyz", "expected xyzxyzxyz")
  assert(str.replace("aaa", "aa", "b") == "ba", "expected non-overlapping replace")
  assert(str.replace("abc", "b", "") == "ac", "expected deletion")
end
test_replace_multichar_and_growth()

local function test_replace_empty_old()
  assert(str.replace("abc", "", "x") == "abc", "expected empty old to be a no-op")
end
test_replace_empty_old()

-- lines tests

local function test_lines_basic()
  local ls = str.lines("a\nb\nc")
  assert(#ls == 3, "expected 3 lines, got " .. #ls)
  assert(ls[1] == "a" and ls[2] == "b" and ls[3] == "c", "expected a,b,c")
end
test_lines_basic()

local function test_lines_trailing_newline()
  local ls = str.lines("a\nb\n")
  assert(#ls == 2, "expected 2 lines, got " .. #ls)
  assert(ls[1] == "a" and ls[2] == "b", "expected a,b")
end
test_lines_trailing_newline()

local function test_lines_crlf()
  local ls = str.lines("a\r\nb\r\n")
  assert(#ls == 2, "expected 2 lines, got " .. #ls)
  assert(ls[1] == "a" and ls[2] == "b", "expected CR stripped")
end
test_lines_crlf()

local function test_lines_empty_and_blank()
  assert(#str.lines("") == 0, "expected no lines for empty string")
  local ls = str.lines("\n")
  assert(#ls == 1 and ls[1] == "", "expected one empty line")
  ls = str.lines("a\n\nb")
  assert(#ls == 3 and ls[2] == "", "expected inner empty line preserved")
end
test_lines_empty_and_blank()

local function test_lines_no_newline()
  local ls = str.lines("solo")
  assert(#ls == 1 and ls[1] == "solo", "expected single line")
end
test_lines_no_newline()

-- partition tests

local function test_partition_found()
  local before, sep, after = str.partition("key=value", "=")
  assert(before == "key", "expected key, got " .. before)
  assert(sep == "=", "expected =")
  assert(after == "value", "expected value, got " .. after)
end
test_partition_found()

local function test_partition_first_occurrence()
  local before, sep, after = str.partition("a=b=c", "=")
  assert(before == "a" and sep == "=" and after == "b=c", "expected split at first =")
end
test_partition_first_occurrence()

local function test_partition_not_found()
  local before, sep, after = str.partition("hello", "=")
  assert(before == "hello", "expected whole string")
  assert(sep == "" and after == "", "expected empty sep and after")
end
test_partition_not_found()

local function test_partition_edges()
  local before, sep, after = str.partition("=v", "=")
  assert(before == "" and sep == "=" and after == "v", "expected empty before")
  before, sep, after = str.partition("k=", "=")
  assert(before == "k" and sep == "=" and after == "", "expected empty after")
  before, sep, after = str.partition("abc", "")
  assert(before == "abc" and sep == "" and after == "", "expected empty sep no-op")
end
test_partition_edges()

local function test_partition_multichar()
  local before, sep, after = str.partition("a::b::c", "::")
  assert(before == "a" and sep == "::" and after == "b::c", "expected multichar sep")
end
test_partition_multichar()

-- fields tests

local function test_fields_basic()
  local fs = str.fields("a b c")
  assert(#fs == 3, "expected 3 fields, got " .. #fs)
  assert(fs[1] == "a" and fs[2] == "b" and fs[3] == "c", "expected a,b,c")
end
test_fields_basic()

local function test_fields_runs_and_edges()
  local fs = str.fields("  a \t b\n\nc  ")
  assert(#fs == 3, "expected 3 fields, got " .. #fs)
  assert(fs[1] == "a" and fs[2] == "b" and fs[3] == "c", "expected a,b,c")
end
test_fields_runs_and_edges()

local function test_fields_empty()
  assert(#str.fields("") == 0, "expected no fields for empty string")
  assert(#str.fields("  \t\n ") == 0, "expected no fields for blank string")
end
test_fields_empty()
