#!/usr/bin/env cosmic
local check = require("cosmic.check")
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
  local regex = check.must(re.compile("world"), "compile failed")
  local result = regex:search("hello world")
  assert(result == "world", "expected 'world', got '" .. tostring(result) .. "'")
end
test_regex_search_match()

local function test_regex_search_no_match()
  local regex = check.must(re.compile("xyz"), "compile failed")
  local result = regex:search("hello world")
  assert(result == nil, "expected nil for no match")
end
test_regex_search_no_match()

local function test_regex_search_beginning()
  local regex = check.must(re.compile("^hello"), "compile failed")
  local result = regex:search("hello world")
  assert(result == "hello", "expected 'hello', got '" .. tostring(result) .. "'")
end
test_regex_search_beginning()

local function test_regex_search_end()
  local regex = check.must(re.compile("world$"), "compile failed")
  local result = regex:search("hello world")
  assert(result == "world", "expected 'world', got '" .. tostring(result) .. "'")
end
test_regex_search_end()

local function test_regex_search_character_class()
  local regex = check.must(re.compile("[0-9]+"), "compile failed")
  local result = regex:search("abc123def")
  assert(result == "123", "expected '123', got '" .. tostring(result) .. "'")
end
test_regex_search_character_class()

local function test_regex_search_alternation()
  local regex = check.must(re.compile("cat|dog"), "compile failed")
  local result = regex:search("I have a dog")
  assert(result == "dog", "expected 'dog', got '" .. tostring(result) .. "'")
end
test_regex_search_alternation()

local function test_regex_search_captures()
  local regex = check.must(re.compile("([a-z]+)([0-9]+)"), "compile failed")
  local result, raw_caps = regex:search("abc123")
  assert(result == "abc123", "expected 'abc123', got '" .. tostring(result) .. "'")
  local caps = check.must(raw_caps, "expected captures table on match")
  assert(#caps == 2, "expected 2 captures, got " .. tostring(#caps))
  assert(caps[1] == "abc", "expected first capture 'abc', got '" .. tostring(caps[1]) .. "'")
  assert(caps[2] == "123", "expected second capture '123', got '" .. tostring(caps[2]) .. "'")
end
test_regex_search_captures()

local function test_regex_search_no_match_no_error()
  -- A no-match from a compiled regex is a single bare nil, not an error.
  local regex = check.must(re.compile("cat"), "compile failed")
  local result, caps = regex:search("dog only")
  assert(result == nil, "expected nil for no match")
  assert(caps == nil, "expected no second value for no match")
end
test_regex_search_no_match_no_error()

-- search convenience function tests

local function test_search_simple()
  local m, err = re.match("hello world", "world")
  assert(err == nil, "expected no error, got: " .. tostring(err))
  local got = check.must(m)
  assert(got.text == "world", "expected 'world', got '" .. tostring(got.text) .. "'")
  assert(#got.caps == 0, "expected empty captures table for pattern without groups")
end
test_search_simple()

local function test_search_no_match()
  -- No match is not an error: a bare nil, no error message.
  local m, err = re.match("hello world", "xyz")
  assert(m == nil, "expected nil for no match")
  assert(err == nil, "expected no error for no match")
end
test_search_no_match()

local function test_search_invalid_pattern()
  local m, err = re.match("hello world", "[invalid")
  assert(m == nil, "expected nil for invalid pattern")
  assert(err ~= nil, "expected error message")
  assert(type(err) == "string", "error should be a string")
end
test_search_invalid_pattern()

local function test_search_captures()
  local m, err = re.match("id 42-abc!", "([0-9]+)-([a-z]+)")
  assert(err == nil, "expected no error, got: " .. tostring(err))
  local got = check.must(m, "expected a match")
  assert(got.text == "42-abc", "expected '42-abc', got '" .. tostring(got.text) .. "'")
  assert(#got.caps == 2, "expected 2 captures, got " .. tostring(#got.caps))
  assert(got.caps[1] == "42", "expected first capture '42'")
  assert(got.caps[2] == "abc", "expected second capture 'abc'")
end
test_search_captures()

local function test_search_nonparticipating_group()
  local m = check.must(re.match("xxaaxx", "(aa)|(bb)"))
  assert(m.text == "aa", "expected 'aa', got '" .. tostring(m.text) .. "'")
  assert(#m.caps == 2, "expected 2 capture slots, got " .. tostring(#m.caps))
  assert(m.caps[1] == "aa", "expected first capture 'aa'")
  assert(m.caps[2] == "", "non-participating group should be empty string")
end
test_search_nonparticipating_group()

local function test_search_regex_metacharacters()
  local m = check.must(re.match("hello", "h.llo"))
  assert(m.text == "hello", "expected 'hello', got '" .. tostring(m.text) .. "'")
end
test_search_regex_metacharacters()

local function test_search_quantifiers()
  local m = check.must(re.match("heeeello world", "he+llo"))
  assert(m.text == "heeeello", "expected 'heeeello', got '" .. tostring(m.text) .. "'")
end
test_search_quantifiers()

local function test_search_optional()
  local m = check.must(re.match("color", "colou?r"))
  assert(m.text == "color", "expected 'color', got '" .. tostring(m.text) .. "'")

  m = check.must(re.match("colour", "colou?r"))
  assert(m.text == "colour", "expected 'colour', got '" .. tostring(m.text) .. "'")
end
test_search_optional()

-- is_match predicate tests: three honest outcomes

local function test_is_match_true()
  local result, err = re.is_match("hello world", "world")
  assert(err == nil, "expected no error")
  assert(result == true, "expected true for matching pattern")
end
test_is_match_true()

local function test_is_match_false()
  local result, err = re.is_match("hello world", "xyz")
  assert(err == nil, "expected no error")
  assert(result == false, "expected false for non-matching pattern")
end
test_is_match_false()

local function test_is_match_invalid_pattern()
  -- A bad pattern is nil + err, not false: "no match" and "your
  -- pattern is invalid" are no longer the same value.
  local result, err = re.is_match("hello world", "[invalid")
  assert(result == nil, "expected nil for invalid pattern")
  assert(err ~= nil, "expected error message")
end
test_is_match_invalid_pattern()

-- flag tests

local function test_ignore_case_option()
  -- Without ignore_case, should not match
  local none = re.match("hello world", "HELLO")
  assert(none == nil, "expected nil without ignore_case")

  -- With ignore_case, should match
  local m = check.must(re.match("hello world", "HELLO", {ignore_case = true}))
  assert(m.text == "hello", "expected 'hello' with ignore_case, got '" .. tostring(m.text) .. "'")
end
test_ignore_case_option()

local function test_compile_ignore_case_option()
  local regex = check.must(re.compile("WORLD", {ignore_case = true}))
  local result = regex:search("hello world")
  assert(result == "world", "expected 'world' with ignore_case")
end
test_compile_ignore_case_option()

-- The raw Regex layer keeps the binding's integer search flags.

local function test_search_flags_exist()
  assert(re.NOTBOL ~= nil, "NOTBOL flag should exist")
  assert(re.NOTEOL ~= nil, "NOTEOL flag should exist")
end
test_search_flags_exist()

-- edge case tests

local function test_empty_pattern()
  local m = check.must(re.match("hello", ""))
  -- Empty pattern matches empty string at start
  assert(m.text == "", "expected empty string match, got '" .. tostring(m.text) .. "'")
end
test_empty_pattern()

local function test_empty_text()
  local m = re.match("", "hello")
  assert(m == nil, "expected nil for empty text")
end
test_empty_text()

local function test_full_match()
  local m = check.must(re.match("hello world", "^hello world$"))
  assert(m.text == "hello world", "expected full match")
end
test_full_match()

local function test_special_characters()
  -- Dot matches any character
  local m = check.must(re.match("abc", "a.c"))
  assert(m.text == "abc", "expected 'abc', got '" .. tostring(m.text) .. "'")
end
test_special_characters()

local function test_escaped_special_characters()
  -- Escaped dot matches literal dot
  local m = check.must(re.match("a.c", "a\\.c"))
  assert(m.text == "a.c", "expected 'a.c', got '" .. tostring(m.text) .. "'")
end
test_escaped_special_characters()

local function test_reuse_compiled_regex()
  local regex = check.must(re.compile("[a-z]+"), "compile failed")

  local r1 = regex:search("123abc456")
  assert(r1 == "abc", "first search failed")

  local r2 = regex:search("xyz789")
  assert(r2 == "xyz", "second search failed")

  local r3 = regex:search("12345")
  assert(r3 == nil, "expected nil for no match")
end
test_reuse_compiled_regex()
