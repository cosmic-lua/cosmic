#!/usr/bin/env cosmic
local re = require("cosmic.re")
local check = require("cosmic.check")

--- The old findall shape, over find_all: every match's text, in order.
--- Also exercises Span fields via the m projection.
local function matches_of(text: string, pat: string, flags?: integer): {string} | nil, string
  local spans, err = re.find_all(text, pat, flags)
  if not spans then
    return nil, err
  end
  local out: {string} = {}
  for i, sp in ipairs(spans) do
    out[i] = sp.m
  end
  return out
end

-- find_all / gmatch tests

local function test_find_all_basic()
  local ms = check.must(matches_of("a1b22c333", "[0-9]+"))
  assert(#ms == 3, "expected 3 matches, got " .. #ms)
  assert(ms[1] == "1" and ms[2] == "22" and ms[3] == "333", "expected 1,22,333")
end
test_find_all_basic()

local function test_find_all_no_match()
  local ms = check.must(matches_of("abc", "[0-9]+"))
  assert(#ms == 0, "expected empty list for no matches")
end
test_find_all_no_match()

local function test_find_all_non_overlapping()
  local ms = check.must(matches_of("aaaa", "aa"))
  assert(#ms == 2, "expected 2 non-overlapping matches, got " .. #ms)
end
test_find_all_non_overlapping()

local function test_find_all_leftmost_longest()
  local ms = check.must(matches_of("abbb ab a", "ab*"))
  assert(#ms == 3, "expected 3 matches, got " .. #ms)
  assert(ms[1] == "abbb" and ms[2] == "ab" and ms[3] == "a", "expected longest matches")
end
test_find_all_leftmost_longest()

local function test_find_all_icase_flag()
  local ms = check.must(matches_of("Foo foo FOO", "foo", re.ICASE))
  assert(#ms == 3, "expected 3 case-insensitive matches, got " .. #ms)
  assert(ms[1] == "Foo" and ms[3] == "FOO", "expected original casing in results")
end
test_find_all_icase_flag()

local function test_find_all_bad_pattern()
  local ms, err = matches_of("abc", "[")
  assert(ms == nil and err ~= nil, "expected error for bad pattern")
end
test_find_all_bad_pattern()

local function test_find_all_empty_capable_rejected()
  local ms, err = matches_of("abc", "x*")
  assert(ms == nil, "expected empty-capable pattern to be rejected")
  assert(err and err:find("empty", 1, true), "expected empty-string error, got: " .. tostring(err))
end
test_find_all_empty_capable_rejected()

-- anchor positioning: the matched text also occurs before the true
-- match position, so naive plain-find placement would corrupt results.

local function test_anchor_dollar_positions_correctly()
  assert(re.gsub("foo", "o$", "0") == "fo0", "expected only the final o replaced")
  assert(re.gsub("banana", "a$", "X") == "bananX", "expected only the final a replaced")
end
test_anchor_dollar_positions_correctly()

local function test_anchor_caret_only_start()
  assert(re.gsub("aaa", "^a", "X") == "Xaa", "expected only the leading a replaced")
  local ms = check.must(matches_of("aa a", "^a+"))
  assert(#ms == 1 and ms[1] == "aa", "expected a single anchored match")
end
test_anchor_caret_only_start()

-- DOCUMENTED LIMITATION (see re.tl locate/find_all doc comments): a
-- `^`/`$` anchor satisfied only via an embedded newline under the
-- NEWLINE flag (not true text start/end) cannot be re-confirmed by
-- locate()'s exact-width verification window, so all_matches gives up
-- as soon as it hits one. This pins today's (regrettable but known)
-- behavior for both flag states, so a future fix changes this test
-- deliberately instead of silently regressing an untested path.
local function test_newline_anchor_past_first_line_is_a_known_limitation()
  -- Without NEWLINE, `^` only matches true text start: one match.
  local ms = check.must(matches_of("foo\nfoo", "^foo"))
  assert(#ms == 1 and ms[1] == "foo", "expected a single match without NEWLINE")

  -- With NEWLINE, `^` should also match right after the embedded \n
  -- (regardless of NOTBOL, per POSIX) -- but locate() cannot verify
  -- that second candidate, so the whole call fails instead of
  -- returning {"foo", "foo"}.
  local ms2, err2 = matches_of("foo\nfoo", "^foo", re.NEWLINE)
  assert(ms2 == nil, "expected the known limitation to surface as nil, not a silent undercount")
  assert(err2 and err2:find("failed to locate", 1, true),
    "expected a 'failed to locate' error, got: " .. tostring(err2))

  -- The symmetric $ case fails differently (a short list, not nil),
  -- which is exactly why this is documented rather than papered over
  -- with one special case.
  local ms3, err3 = matches_of("foo\nfoo\nfoo", "foo$", re.NEWLINE)
  assert(ms3 ~= nil and #ms3 == 1, "expected the documented undercount, got: "
    .. tostring(ms3) .. " " .. tostring(err3))
end
test_newline_anchor_past_first_line_is_a_known_limitation()

-- split tests

local function test_split_basic()
  local fields = check.must(re.split("a1b22c", "[0-9]+"))
  assert(#fields == 3, "expected 3 fields, got " .. #fields)
  assert(fields[1] == "a" and fields[2] == "b" and fields[3] == "c", "expected a,b,c")
end
test_split_basic()

local function test_split_edges_and_adjacent()
  local fields = check.must(re.split("-a--b-", "-"))
  assert(#fields == 5, "expected 5 fields, got " .. #fields)
  assert(fields[1] == "" and fields[2] == "a" and fields[3] == "", "expected empty edge fields")
  assert(fields[4] == "b" and fields[5] == "", "expected trailing empty field")
end
test_split_edges_and_adjacent()

local function test_split_no_match()
  local fields = check.must(re.split("abc", ","))
  assert(#fields == 1 and fields[1] == "abc", "expected whole string field")
end
test_split_no_match()

local function test_split_whitespace_runs()
  local fields = check.must(re.split("a  b\tc", "[ \t]+"))
  assert(#fields == 3, "expected 3 fields, got " .. #fields)
  assert(fields[3] == "c", "expected c")
end
test_split_whitespace_runs()

-- gsub tests

local function test_gsub_literal()
  assert(re.gsub("a1b22c", "[0-9]+", "#") == "a#b#c", "expected digits replaced")
  assert(re.gsub("abc", "x", "y") == "abc", "expected no-match text unchanged")
end
test_gsub_literal()

local function test_gsub_replacement_is_plain()
  -- No capture references: %1 and & are literal text in the replacement.
  assert(re.gsub("abc", "b", "%1") == "a%1c", "expected %1 kept literal")
  assert(re.gsub("abc", "b", "&") == "a&c", "expected & kept literal")
end
test_gsub_replacement_is_plain()

local function test_gsub_function_repl()
  local out = assert(re.gsub("a1b22c", "[0-9]+", function(m: string, _caps: {string}): string
        return "<" .. m .. ">"
      end))
  assert(out == "a<1>b<22>c", "expected wrapped digits, got " .. tostring(out))
end
test_gsub_function_repl()

local function test_gsub_function_uses_captures()
  local out = assert(re.gsub("x=1, y=22", "([a-z]+)=([0-9]+)", function(_m: string, caps: {string}): string
        return caps[2] .. "=" .. caps[1]
      end))
  assert(out == "1=x, 22=y", "expected swapped pairs, got " .. tostring(out))
end
test_gsub_function_uses_captures()

local function test_gsub_function_nil_keeps_match()
  local out = assert(re.gsub("a1b22c", "[0-9]+", function(m: string, _caps: {string}): string
        if m == "22" then
          return "<22>"
        end
        return nil
      end))
  assert(out == "a1b<22>c", "expected nil return to keep match, got " .. tostring(out))
end
test_gsub_function_nil_keeps_match()

local function test_gsub_whole_string_match()
  assert(re.gsub("abc", "^abc$", "X") == "X", "expected whole-string match replaced")
end
test_gsub_whole_string_match()

local function test_gsub_bad_pattern_and_empty_capable()
  local out, err = re.gsub("abc", "[", "x")
  assert(out == nil and err ~= nil, "expected error for bad pattern")
  out, err = re.gsub("abc", "a?", "x")
  assert(out == nil and err ~= nil, "expected empty-capable pattern rejected")
end
test_gsub_bad_pattern_and_empty_capable()

local function test_find_reports_position()
  local sp = check.must(re.find("a1b22c", "[0-9]+"))
  assert(sp.s == 2 and sp.e == 2 and sp.m == "1",
    "expected first match '1' at 2..2, got " .. sp.m .. " at " .. sp.s .. ".." .. sp.e)
  local none = re.find("abc", "[0-9]+")
  assert(none == nil, "no match is bare nil")
  local bad, err = re.find("abc", "[")
  assert(bad == nil and err ~= nil, "a bad pattern reports an error")
end
test_find_reports_position()

local function test_gmatch_iterates_matches_and_caps()
  local iter = check.must(re.gmatch("a1b22c333", "([0-9])([0-9]*)"))
  local got: {string} = {}
  local first_caps: {string} = nil
  for m, caps in iter do
    got[#got + 1] = m
    if not first_caps then first_caps = caps end
  end
  assert(#got == 3 and got[3] == "333", "expected 3 matches ending 333")
  assert(first_caps[1] == "1" and first_caps[2] == "", "caps carried through")
  local bad, err = re.gmatch("abc", "[")
  assert(bad == nil and err ~= nil, "a bad pattern reports an error, not an iterator")
end
test_gmatch_iterates_matches_and_caps()
