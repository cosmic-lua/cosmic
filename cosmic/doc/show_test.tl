#!/usr/bin/env lua
--- Tests for cosmic.doc.show: query strings must not be interpreted as
--- Lua patterns when matched against example names.

local docs_render = require("cosmic.doc.show")
local doc_types = require("cosmic.doc.types")

local function example(name: string): doc_types.ExampleDoc
  return {name = name, description = "", body = "", expected_output = "", line = 1}
end

-- A function name containing Lua pattern magic characters ("(", ")",
-- "-", ".") must still match its own examples by plain prefix, and
-- must not throw or mismatch because the name was spliced unescaped
-- into a pattern.
local function test_find_matching_examples_escapes_magic_chars()
  local examples = {
    example("Example_do(thing)_basic"),
    example("Example_unrelated"),
  }
  local matches = docs_render.find_matching_examples(examples, "do(thing)")
  assert(#matches == 1, "expected 1 match, got " .. #matches)
  assert(matches[1].name == "Example_do(thing)_basic", "got: " .. matches[1].name)
end
test_find_matching_examples_escapes_magic_chars()

local function test_find_matching_examples_dash_and_dot()
  local examples = {
    example("Example_a-b.c_variant"),
  }
  local matches = docs_render.find_matching_examples(examples, "a-b.c")
  assert(#matches == 1, "expected 1 match, got " .. #matches)
end
test_find_matching_examples_dash_and_dot()

local function test_find_matching_examples_exact_match_still_works()
  local examples = {example("Example_greet")}
  local matches = docs_render.find_matching_examples(examples, "greet")
  assert(#matches == 1, "expected 1 match, got " .. #matches)
end
test_find_matching_examples_exact_match_still_works()

local function test_find_matching_examples_no_false_prefix_match()
  -- "greet" must not match "greeting_extra" (no separating "_").
  local examples = {example("Example_greeting_extra")}
  local matches = docs_render.find_matching_examples(examples, "greet")
  assert(#matches == 0, "expected 0 matches, got " .. #matches)
end
test_find_matching_examples_no_false_prefix_match()
