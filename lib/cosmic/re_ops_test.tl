#!/usr/bin/env cosmic
local re = require("cosmic.re")
local check = require("cosmic.check")

-- findall tests

local function test_findall_basic()
  local ms = check.must(re.findall("[0-9]+", "a1b22c333"))
  assert(#ms == 3, "expected 3 matches, got " .. #ms)
  assert(ms[1] == "1" and ms[2] == "22" and ms[3] == "333", "expected 1,22,333")
end
test_findall_basic()

local function test_findall_no_match()
  local ms = check.must(re.findall("[0-9]+", "abc"))
  assert(#ms == 0, "expected empty list for no matches")
end
test_findall_no_match()

local function test_findall_non_overlapping()
  local ms = check.must(re.findall("aa", "aaaa"))
  assert(#ms == 2, "expected 2 non-overlapping matches, got " .. #ms)
end
test_findall_non_overlapping()

local function test_findall_leftmost_longest()
  local ms = check.must(re.findall("ab*", "abbb ab a"))
  assert(#ms == 3, "expected 3 matches, got " .. #ms)
  assert(ms[1] == "abbb" and ms[2] == "ab" and ms[3] == "a", "expected longest matches")
end
test_findall_leftmost_longest()

local function test_findall_icase_flag()
  local ms = check.must(re.findall("foo", "Foo foo FOO", re.ICASE))
  assert(#ms == 3, "expected 3 case-insensitive matches, got " .. #ms)
  assert(ms[1] == "Foo" and ms[3] == "FOO", "expected original casing in results")
end
test_findall_icase_flag()

local function test_findall_bad_pattern()
  local ms, err = re.findall("[", "abc")
  assert(ms == nil and err ~= nil, "expected error for bad pattern")
end
test_findall_bad_pattern()

local function test_findall_empty_capable_rejected()
  local ms, err = re.findall("x*", "abc")
  assert(ms == nil, "expected empty-capable pattern to be rejected")
  assert(err and err:find("empty", 1, true), "expected empty-string error, got: " .. tostring(err))
end
test_findall_empty_capable_rejected()

-- anchor positioning: the matched text also occurs before the true
-- match position, so naive plain-find placement would corrupt results.

local function test_anchor_dollar_positions_correctly()
  assert(re.gsub("o$", "foo", "0") == "fo0", "expected only the final o replaced")
  assert(re.gsub("a$", "banana", "X") == "bananX", "expected only the final a replaced")
end
test_anchor_dollar_positions_correctly()

local function test_anchor_caret_only_start()
  assert(re.gsub("^a", "aaa", "X") == "Xaa", "expected only the leading a replaced")
  local ms = check.must(re.findall("^a+", "aa a"))
  assert(#ms == 1 and ms[1] == "aa", "expected a single anchored match")
end
test_anchor_caret_only_start()

-- split tests

local function test_split_basic()
  local fields = check.must(re.split("[0-9]+", "a1b22c"))
  assert(#fields == 3, "expected 3 fields, got " .. #fields)
  assert(fields[1] == "a" and fields[2] == "b" and fields[3] == "c", "expected a,b,c")
end
test_split_basic()

local function test_split_edges_and_adjacent()
  local fields = check.must(re.split("-", "-a--b-"))
  assert(#fields == 5, "expected 5 fields, got " .. #fields)
  assert(fields[1] == "" and fields[2] == "a" and fields[3] == "", "expected empty edge fields")
  assert(fields[4] == "b" and fields[5] == "", "expected trailing empty field")
end
test_split_edges_and_adjacent()

local function test_split_no_match()
  local fields = check.must(re.split(",", "abc"))
  assert(#fields == 1 and fields[1] == "abc", "expected whole string as one field")
end
test_split_no_match()

local function test_split_whitespace_runs()
  local fields = check.must(re.split("[ \t]+", "a  b\tc"))
  assert(#fields == 3, "expected 3 fields, got " .. #fields)
  assert(fields[3] == "c", "expected c")
end
test_split_whitespace_runs()

-- gsub tests

local function test_gsub_literal()
  assert(re.gsub("[0-9]+", "a1b22c", "#") == "a#b#c", "expected digits replaced")
  assert(re.gsub("x", "abc", "y") == "abc", "expected no-match text unchanged")
end
test_gsub_literal()

local function test_gsub_replacement_is_plain()
  -- No capture references: %1 and & are literal text in the replacement.
  assert(re.gsub("b", "abc", "%1") == "a%1c", "expected %1 kept literal")
  assert(re.gsub("b", "abc", "&") == "a&c", "expected & kept literal")
end
test_gsub_replacement_is_plain()

local function test_gsub_function_repl()
  local out = assert(re.gsub("[0-9]+", "a1b22c", function(m: string, _caps: {string}): string
        return "<" .. m .. ">"
      end))
  assert(out == "a<1>b<22>c", "expected wrapped digits, got " .. tostring(out))
end
test_gsub_function_repl()

local function test_gsub_function_uses_captures()
  local out = assert(re.gsub("([a-z]+)=([0-9]+)", "x=1, y=22", function(_m: string, caps: {string}): string
        return caps[2] .. "=" .. caps[1]
      end))
  assert(out == "1=x, 22=y", "expected swapped pairs, got " .. tostring(out))
end
test_gsub_function_uses_captures()

local function test_gsub_function_nil_keeps_match()
  local out = assert(re.gsub("[0-9]+", "a1b22c", function(m: string, _caps: {string}): string
        if m == "22" then
          return "<22>"
        end
        return nil
      end))
  assert(out == "a1b<22>c", "expected nil return to keep match, got " .. tostring(out))
end
test_gsub_function_nil_keeps_match()

local function test_gsub_whole_string_match()
  assert(re.gsub("^abc$", "abc", "X") == "X", "expected whole-string match replaced")
end
test_gsub_whole_string_match()

local function test_gsub_bad_pattern_and_empty_capable()
  local out, err = re.gsub("[", "abc", "x")
  assert(out == nil and err ~= nil, "expected error for bad pattern")
  out, err = re.gsub("a?", "abc", "x")
  assert(out == nil and err ~= nil, "expected empty-capable pattern rejected")
end
test_gsub_bad_pattern_and_empty_capable()
