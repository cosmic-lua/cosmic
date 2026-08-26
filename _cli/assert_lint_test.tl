#!/usr/bin/env cosmic
-- The return-assert rule: `return assert(v, msg)` type-checks as one
-- value and returns two, because Lua's assert passes its arguments
-- through while the carried tl patch declares a single return.

local assert_lint = require("_cli.assert_lint")
local check = require("cosmic.check")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over a source string, as lint_file does.
local function diagnose(source: string): {Diagnostic}
  return assert_lint.check_return_assert("fixture.tl", source)
end

local FN < const > = "local function f(a: string): string\n"

local function test_multi_argument_return_assert_is_flagged()
  local diags = diagnose(FN .. "  return assert(a, \"f: nil\")\nend\n")
  check.equal(#diags, 1, "a two-argument return assert must be flagged")
  check.equal(diags[1].rule, "return-assert")
  check.equal(diags[1].line, 2)
  check.truthy(diags[1].message:find("declares one return", 1, true),
    "the message names the declared arity")
  check.truthy(diags[1].message:find("assert as a statement", 1, true),
    "the message names the fix")
end
test_multi_argument_return_assert_is_flagged()

local function test_single_argument_return_assert_passes()
  -- assert(v) returns one value at runtime; the declaration is honest.
  check.equal(#diagnose(FN .. "  return assert(a)\nend\n"), 0,
    "a one-argument return assert is not the trap")
end
test_single_argument_return_assert_passes()

local function test_non_final_return_assert_passes()
  -- Only the last expression of a return list expands, so an assert
  -- ahead of another value is truncated to one.
  check.equal(#diagnose(FN .. "  return assert(a, \"f: nil\"), a\nend\n"), 0,
    "an assert that is not the last return expression is truncated")
end
test_non_final_return_assert_passes()

local function test_parenthesized_return_assert_passes()
  check.equal(#diagnose(FN .. "  return (assert(a, \"f: nil\"))\nend\n"), 0,
    "parentheses truncate the call to one value")
end
test_parenthesized_return_assert_passes()

local function test_concatenated_return_assert_passes()
  check.equal(#diagnose(FN .. "  return assert(a, \"f: nil\") .. a\nend\n"), 0,
    "a call inside a larger expression is already truncated")
end
test_concatenated_return_assert_passes()

local function test_check_must_passes()
  -- check.must is a real one-value Teal function, not Lua's assert.
  check.equal(#diagnose(FN .. "  return check.must(a, \"f: nil\")\nend\n"), 0,
    "check.must returns exactly one value and must not be flagged")
end
test_check_must_passes()

local function test_field_named_assert_passes()
  check.equal(#diagnose(FN .. "  return t.assert(a, \"f: nil\")\nend\n"), 0,
    "the rule is about the bare global assert")
end
test_field_named_assert_passes()

local function test_assert_inside_a_string_passes()
  local src = FN .. "  return \"return assert(a, 'x')\"\nend\n"
  check.equal(#diagnose(src), 0, "a quoted assert is not code")
end
test_assert_inside_a_string_passes()

local function test_statement_position_assert_passes()
  local src = FN .. "  assert(a, \"f: nil\")\n  return a\nend\n"
  check.equal(#diagnose(src), 0,
    "the licensed shape — assert as a statement — stays legal")
end
test_statement_position_assert_passes()

local function test_bare_return_passes()
  check.equal(#diagnose("local function f()\n  return\nend\n"), 0,
    "a valueless return has no last expression")
end
test_bare_return_passes()

local function test_nested_function_return_is_reached()
  local src = "local function outer(): function(string): string\n" ..
  "  return function(a: string): string\n" ..
  "    return assert(a, \"inner: nil\")\n" ..
  "  end\n" ..
  "end\n"
  local diags = diagnose(src)
  check.equal(#diags, 1, "a return inside a function expression is checked")
  check.equal(diags[1].line, 3)
end
test_nested_function_return_is_reached()
