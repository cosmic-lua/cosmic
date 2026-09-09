#!/usr/bin/env cosmic
-- cosmic.format lexical preservation tests

local tl = require("tl")
local preserve = require("cosmic.format.preserve")

local function tokens(source: string): {tl.Token}
  local result, errors = tl.lex(source, "preserve_test.tl")
  assert(not errors or #errors == 0, "fixture must lex")
  return result
end

local function assert_same(before: string, after: string, message: string)
  local same, why = preserve.equivalent(tokens(before), tokens(after))
  assert(same, message .. ": " .. why)
end

local function assert_different(before: string, after: string, message: string)
  local same = preserve.equivalent(tokens(before), tokens(after))
  assert(not same, message)
end

local function test_layout_changes_preserve_the_stream()
  assert_same("local x=1 -- tail   \n", "local x = 1 -- tail\n",
    "spaces and normalized comment tails are layout")
end

local function test_changed_literal_value_is_detected()
  assert_different("return \"one\"\n", "return \"two\"\n",
    "a changed string literal must be detected")
  assert_different("return 0x10\n", "return 16\n",
    "a changed numeric spelling must be detected")
end

local function test_changed_comments_are_detected()
  assert_different("-- one\nreturn 1\n", "-- two\nreturn 1\n",
    "changed comment text must be detected")
  assert_different("-- one\nreturn 1\n", "return 1\n",
    "a removed comment must be detected")
end

local function test_long_comment_reindent_is_layout()
  assert_same("--[[\n  body\n]]\nreturn 1\n", "--[[\n    body\n  ]]\nreturn 1\n",
    "long comment continuation indentation is layout")
end

local function test_token_merging_is_detected()
  assert_different("return - -1\n", "return --1\n",
    "minus tokens must not become a comment")
end
