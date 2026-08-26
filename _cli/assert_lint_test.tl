#!/usr/bin/env cosmic
-- The two assert rules. `return-assert`: `return assert(v, msg)`
-- type-checks as one value and returns two, because Lua's assert passes
-- its arguments through while the carried tl patch declares a single
-- return. `assert-justify`: a library assert throws, so D23 licenses one
-- only where it carries a `-- assert:` reason.

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

-- assert-justify: the licence half. The rule reads the file's lines for
-- the marker, so every fixture below is split the way lint_file splits.

--- Run assert-justify over a source string at a chosen path.
local function justify(path: string, source: string): {Diagnostic}
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  return assert_lint.check_assert_justification(path, source, lines)
end

local LIB < const > = "cosmic/time.tl"

local function test_unjustified_library_assert_is_flagged()
  local diags = justify(LIB, "local t = assert(now())\n")
  check.equal(#diags, 1, "a library assert with no reason must be flagged")
  check.equal(diags[1].rule, "assert-justify")
  check.equal(diags[1].line, 1)
  check.truthy(diags[1].message:find("-- assert:", 1, true),
    "the message names the marker")
  check.truthy(diags[1].message:find("guide.lint", 1, true),
    "the message names where the rule is written down")
end
test_unjustified_library_assert_is_flagged()

local function test_trailing_reason_justifies()
  check.equal(#justify(LIB,
      "local t = assert(now()) -- assert: CLOCK_REALTIME always resolves\n"), 0,
    "a trailing reason is the licensed shape")
end
test_trailing_reason_justifies()

local function test_reason_on_the_line_above_justifies()
  check.equal(#justify(LIB,
      "  -- assert: CLOCK_REALTIME always resolves\n"
      .. "  local t = assert(now())\n"), 0,
    "90 columns may not fit the reason, so the line above counts")
end
test_reason_on_the_line_above_justifies()

local function test_a_marker_with_no_reason_is_still_flagged()
  check.equal(#justify(LIB, "local t = assert(now()) -- assert:\n"), 1,
    "the marker without a reason justifies nothing")
end
test_a_marker_with_no_reason_is_still_flagged()

local function test_a_cast_marker_does_not_justify_an_assert()
  check.equal(#justify(LIB, "local t = assert(now()) -- cast: from any\n"), 1,
    "the two markers are separate licences")
end
test_a_cast_marker_does_not_justify_an_assert()

local function test_source_outside_cosmic_is_not_governed()
  -- D23 governs cosmic.* modules; the toolchain trees are not library
  -- code, and a test asserts by design.
  check.equal(#justify("_cli/lint.tl", "local t = assert(now())\n"), 0,
    "only cosmic/** library source is governed")
  check.equal(#justify("cosmic/time_test.tl", "local t = assert(now())\n"), 0,
    "a test file asserts freely")
  check.equal(#justify("cosmic/time_example.tl", "local t = assert(now())\n"), 0,
    "so does an example")
end
test_source_outside_cosmic_is_not_governed()

local function test_a_field_named_assert_is_not_the_global()
  check.equal(#justify(LIB, "local t = x.assert(v)\nlocal u = x:assert(v)\n"), 0,
    "the rule is about the bare global assert")
end
test_a_field_named_assert_is_not_the_global()

local function test_assert_inside_a_quoted_string_is_not_code()
  check.equal(#justify(LIB, "local hint = \"try assert(v) here\"\n"), 0,
    "a quoted assert is not a throw")
end
test_assert_inside_a_quoted_string_is_not_code()

local function test_assert_inside_a_long_bracket_is_not_code()
  -- cosmic/embed/init.tl's shape: a line of the entry wrapper this tree
  -- WRITES, carried as a long-bracket payload rather than run.
  local src = "local WRAP = [[\nlocal chunk = assert(loadfile(\"/zip/m.lua\"))\n]]\n"
  check.equal(#justify(LIB, src), 0, "a long-bracket payload is not code")
end
test_assert_inside_a_long_bracket_is_not_code()

local function test_two_asserts_on_one_line_yield_one_diagnostic()
  check.equal(#justify(LIB, "local t, u = assert(a()), assert(b())\n"), 1,
    "one comment covers the line, so one diagnostic asks for it")
end
test_two_asserts_on_one_line_yield_one_diagnostic()
