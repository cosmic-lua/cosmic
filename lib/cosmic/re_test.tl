#!/usr/bin/env cosmic
local re = require("cosmic.re")

-- compile tests

local function test_compile_simple()
  local regex, err = re.compile("hello")
  assert(regex ~= nil, "expected compiled regex, got error: " .. tostring(err))
  assert(err == nil, "expected no error")
end
test_compile_simple()

local function test_compile_with_groups()
  local regex, err = re.compile("(foo|bar)")
  assert(regex ~= nil, "expected compiled regex with groups")
  assert(err == nil, "expected no error")
end
test_compile_with_groups()

local function test_compile_invalid_pattern()
  local regex, err = re.compile("[invalid")
  assert(regex == nil, "expected nil for invalid pattern")
  assert(err ~= nil, "expected error message for invalid pattern")
  assert(type(err) == "string", "error should be a string")
end
test_compile_invalid_pattern()

local function test_compile_invalid_unbalanced_parens()
  local regex, err = re.compile("(unbalanced")
  assert(regex == nil, "expected nil for unbalanced parens")
  assert(err ~= nil, "expected error message")
end
test_compile_invalid_unbalanced_parens()

-- search with compiled regex tests

local function test_regex_search_match()
  local regex = re.compile("world")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("hello world")
  assert(result == "world", "expected 'world', got '" .. tostring(result) .. "'")
end
test_regex_search_match()

local function test_regex_search_no_match()
  local regex = re.compile("xyz")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("hello world")
  assert(result == nil, "expected nil for no match")
end
test_regex_search_no_match()

local function test_regex_search_beginning()
  local regex = re.compile("^hello")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("hello world")
  assert(result == "hello", "expected 'hello', got '" .. tostring(result) .. "'")
end
test_regex_search_beginning()

local function test_regex_search_end()
  local regex = re.compile("world$")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("hello world")
  assert(result == "world", "expected 'world', got '" .. tostring(result) .. "'")
end
test_regex_search_end()

local function test_regex_search_character_class()
  local regex = re.compile("[0-9]+")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("abc123def")
  assert(result == "123", "expected '123', got '" .. tostring(result) .. "'")
end
test_regex_search_character_class()

local function test_regex_search_alternation()
  local regex = re.compile("cat|dog")
  assert(regex, "compile failed")
  local result = (regex as re.Regex):search("I have a dog")
  assert(result == "dog", "expected 'dog', got '" .. tostring(result) .. "'")
end
test_regex_search_alternation()

local function test_regex_search_captures()
  local regex = re.compile("([a-z]+)([0-9]+)")
  assert(regex, "compile failed")
  local result, caps = (regex as re.Regex):search("abc123")
  assert(result == "abc123", "expected 'abc123', got '" .. tostring(result) .. "'")
  assert(caps ~= nil, "expected captures table on match")
  assert(#caps == 2, "expected 2 captures, got " .. tostring(#caps))
  assert(caps[1] == "abc", "expected first capture 'abc', got '" .. tostring(caps[1]) .. "'")
  assert(caps[2] == "123", "expected second capture '123', got '" .. tostring(caps[2]) .. "'")
end
test_regex_search_captures()

local function test_regex_search_no_match_no_error()
  -- A no-match from a compiled regex is a single bare nil, not an error.
  local regex = re.compile("cat")
  assert(regex, "compile failed")
  local result, caps = (regex as re.Regex):search("dog only")
  assert(result == nil, "expected nil for no match")
  assert(caps == nil, "expected no second value for no match")
end
test_regex_search_no_match_no_error()

-- search convenience function tests

local function test_search_simple()
  local result, caps, err = re.search("world", "hello world")
  assert(err == nil, "expected no error, got: " .. tostring(err))
  assert(result == "world", "expected 'world', got '" .. tostring(result) .. "'")
  local c = caps as {string}
  assert(c ~= nil and #c == 0, "expected empty captures table for pattern without groups")
end
test_search_simple()

local function test_search_no_match()
  -- No match is not an error: a bare nil, no captures, no error message.
  local result, caps, err = re.search("xyz", "hello world")
  assert(result == nil, "expected nil for no match")
  assert(caps == nil, "expected nil captures for no match")
  assert(err == nil, "expected no error for no match")
end
test_search_no_match()

local function test_search_invalid_pattern()
  local result, caps, err = re.search("[invalid", "hello world")
  assert(result == nil, "expected nil for invalid pattern")
  assert(caps == nil, "expected nil captures for invalid pattern")
  assert(err ~= nil, "expected error message")
  assert(type(err) == "string", "error should be a string")
end
test_search_invalid_pattern()

local function test_search_captures()
  local result, caps, err = re.search("([0-9]+)-([a-z]+)", "id 42-abc!")
  assert(err == nil, "expected no error, got: " .. tostring(err))
  assert(result == "42-abc", "expected '42-abc', got '" .. tostring(result) .. "'")
  local c = caps as {string}
  assert(c ~= nil, "expected captures table")
  assert(#c == 2, "expected 2 captures, got " .. tostring(#c))
  assert(c[1] == "42", "expected first capture '42', got '" .. tostring(c[1]) .. "'")
  assert(c[2] == "abc", "expected second capture 'abc', got '" .. tostring(c[2]) .. "'")
end
test_search_captures()

local function test_search_nonparticipating_group()
  local result, caps = re.search("(aa)|(bb)", "xxaaxx")
  assert(result == "aa", "expected 'aa', got '" .. tostring(result) .. "'")
  local c = caps as {string}
  assert(#c == 2, "expected 2 capture slots, got " .. tostring(#c))
  assert(c[1] == "aa", "expected first capture 'aa', got '" .. tostring(c[1]) .. "'")
  assert(c[2] == "", "non-participating group should be empty string, got '" .. tostring(c[2]) .. "'")
end
test_search_nonparticipating_group()

local function test_search_regex_metacharacters()
  local result = re.search("h.llo", "hello")
  assert(result == "hello", "expected 'hello', got '" .. tostring(result) .. "'")
end
test_search_regex_metacharacters()

local function test_search_quantifiers()
  local result = re.search("he+llo", "heeeello world")
  assert(result == "heeeello", "expected 'heeeello', got '" .. tostring(result) .. "'")
end
test_search_quantifiers()

local function test_search_optional()
  local result = re.search("colou?r", "color")
  assert(result == "color", "expected 'color', got '" .. tostring(result) .. "'")

  result = re.search("colou?r", "colour")
  assert(result == "colour", "expected 'colour', got '" .. tostring(result) .. "'")
end
test_search_optional()

-- match convenience function tests

local function test_match_true()
  local result, err = re.test("world", "hello world")
  assert(err == nil, "expected no error")
  assert(result == true, "expected true for matching pattern")
end
test_match_true()

local function test_match_false()
  local result, err = re.test("xyz", "hello world")
  assert(err == nil, "expected no error")
  assert(result == false, "expected false for non-matching pattern")
end
test_match_false()

local function test_match_invalid_pattern()
  local result, err = re.test("[invalid", "hello world")
  assert(result == false, "expected false for invalid pattern")
  assert(err ~= nil, "expected error message")
end
test_match_invalid_pattern()

-- flag tests

local function test_icase_flag()
  -- Without ICASE, should not match
  local result = re.search("HELLO", "hello world")
  assert(result == nil, "expected nil without ICASE flag")

  -- With ICASE, should match
  result = re.search("HELLO", "hello world", re.ICASE)
  assert(result == "hello", "expected 'hello' with ICASE flag, got '" .. tostring(result) .. "'")
end
test_icase_flag()

local function test_compile_icase_flag()
  local regex, err = re.compile("WORLD", re.ICASE)
  assert(regex ~= nil, "expected compiled regex: " .. tostring(err))
  local result = (regex as re.Regex):search("hello world")
  assert(result == "world", "expected 'world' with ICASE flag")
end
test_compile_icase_flag()

-- flag constants existence tests

local function test_flags_exist()
  assert(re.BASIC ~= nil, "BASIC flag should exist")
  assert(re.ICASE ~= nil, "ICASE flag should exist")
  assert(re.NEWLINE ~= nil, "NEWLINE flag should exist")
  assert(re.NOSUB ~= nil, "NOSUB flag should exist")
  assert(re.NOTBOL ~= nil, "NOTBOL flag should exist")
  assert(re.NOTEOL ~= nil, "NOTEOL flag should exist")
end
test_flags_exist()

-- edge case tests

local function test_empty_pattern()
  local result = re.search("", "hello")
  -- Empty pattern matches empty string at start
  assert(result == "", "expected empty string match, got '" .. tostring(result) .. "'")
end
test_empty_pattern()

local function test_empty_text()
  local result = re.search("hello", "")
  assert(result == nil, "expected nil for empty text")
end
test_empty_text()

local function test_full_match()
  local result = re.search("^hello world$", "hello world")
  assert(result == "hello world", "expected full match")
end
test_full_match()

local function test_special_characters()
  -- Dot matches any character
  local result = re.search("a.c", "abc")
  assert(result == "abc", "expected 'abc', got '" .. tostring(result) .. "'")
end
test_special_characters()

local function test_escaped_special_characters()
  -- Escaped dot matches literal dot
  local result = re.search("a\\.c", "a.c")
  assert(result == "a.c", "expected 'a.c', got '" .. tostring(result) .. "'")
end
test_escaped_special_characters()

local function test_reuse_compiled_regex()
  local regex = re.compile("[a-z]+")
  assert(regex, "compile failed")

  local r1 = (regex as re.Regex):search("123abc456")
  assert(r1 == "abc", "first search failed")

  local r2 = (regex as re.Regex):search("xyz789")
  assert(r2 == "xyz", "second search failed")

  local r3 = (regex as re.Regex):search("12345")
  assert(r3 == nil, "expected nil for no match")
end
test_reuse_compiled_regex()
