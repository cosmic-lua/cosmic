#!/usr/bin/env cosmic
-- The property that ties cosmic.literal to cosmic.format: a file
-- literal.format writes is a file --check fmt leaves alone.
--
-- A stdlib that writes source its own binary's formatter would rewrite
-- makes every generated file a gate failure waiting to happen, which is
-- what a repo's ratchets discovered by hand-rolling renderers around it.
-- The test lives beside the formatter rather than in
-- cosmic/literal_test.tl because it imports cosmic.format, and
-- cosmic.literal must stay importable in a STRIPPED artifact — one that
-- has dropped the compiler the formatter needs. Keeping the import on
-- this side of the boundary is what keeps that true.

local fmt = require("cosmic.format")
local literal = require("cosmic.literal")

--- Format a value, then assert the formatter returns those exact bytes.
local function assert_fixpoint(v: any, msg: string)
  local src, err = literal.format(v)
  assert(src, msg .. ": literal.format failed: " .. tostring(err))
  local result = fmt.format(src, "x.tl")
  assert(result.ok, msg .. ": the formatter refused what literal wrote:\n" .. src)
  assert(result.code == src, msg ..
    ": not a fixpoint\n  wrote:\n" .. src ..
    "  formatter returned:\n" .. tostring(result.code))
end

-- A nested value: the indent, the trailing commas and the bracketed
-- keys all have to be what the formatter would have chosen.
local function test_a_nested_literal_is_a_fmt_fixpoint()
  assert_fixpoint({
      name = "cosmic", count = 42, flag = true,
      nested = {x = 1.5, y = "two", deeper = {z = false}},
    }, "nested")
end
test_a_nested_literal_is_a_fmt_fixpoint()

-- The empty table has its own spelling, `return {}`, because `return {\n}`
-- is not what the formatter emits for one.
local function test_the_empty_table_is_a_fmt_fixpoint()
  assert_fixpoint({}, "empty")
end
test_the_empty_table_is_a_fmt_fixpoint()

-- The bytes that break a naive renderer: a quote, a newline (which %q
-- writes as a backslash and a REAL newline unless it is rewritten), a
-- tab, a control character and negative numbers.
local function test_awkward_strings_and_numbers_are_a_fmt_fixpoint()
  assert_fixpoint({
      quoted = 'he said "hi"',
      multiline = "first\nsecond\nthird",
      tabbed = "a\tb",
      control = "\1\2\3",
      ["a\nkey"] = "newline in the key too",
      negative = -7,
      fractional = -1.25,
    }, "awkward")
end
test_awkward_strings_and_numbers_are_a_fmt_fixpoint()

-- A flat nested table renders inline, and the inline form -- including
-- its empty spelling -- is also a fixpoint.
local function test_a_flat_nested_table_is_inline_and_a_fmt_fixpoint()
  assert_fixpoint({
      ["a.tl"] = {["covered"] = 1, ["total"] = 2},
      ["b.tl"] = {},
    }, "flat nested")
end
test_a_flat_nested_table_is_inline_and_a_fmt_fixpoint()

print("all literal-format fixpoint tests passed")
