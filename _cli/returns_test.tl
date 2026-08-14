#!/usr/bin/env cosmic
-- The returns invariant, exercised on both sides: a fallible signature
-- that carries a slot past the error is flagged, and every shape that
-- is NOT that — infallible tuples, two-slot fallibles, marked foreign
-- shapes — is left alone. The false-negative half matters as much as
-- the positive one: a rule that fires on `string.partition` would be
-- turned off within a week.

local check = require("cosmic.check")
local returns = require("_cli.returns")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over a source string, as lint_file does.
local function diagnose(source: string): {Diagnostic}
  return returns.check_fallible_returns("t.tl", source)
end

--- How many slots the rule counted, for a source it flags exactly once.
local function slots_reported(source: string): integer
  local diags = diagnose(source)
  check.equal(#diags, 1, "expected exactly one diagnostic for:\n" .. source)
  local n = diags[1].message:match("declares (%d+) slots")
  return math.tointeger(tonumber(n))
end

local function test_flags_error_in_slot_three()
  local diags = diagnose(
    "local function f(): any, boolean, string\n  return nil\nend\n")
  check.equal(#diags, 1, "sqlite's old query_value shape must be flagged")
  check.equal(diags[1].rule, "fallible-returns")
  check.equal(diags[1].line, 1)
end
test_flags_error_in_slot_three()

local function test_flags_slots_past_the_error()
  check.equal(slots_reported(
      "local function f(): Iter | nil, string, any, any\n  return nil\nend\n"), 4,
    "find_iter's old iterator+guard shape must be flagged, all four slots")
end
test_flags_slots_past_the_error()

local function test_counts_a_union_slot_once()
  check.equal(slots_reported(
      "local function f(): {string} | nil, string, {string}\n  return nil\nend\n"), 3,
    "a nil-union is ONE slot, not two")
end
test_counts_a_union_slot_once()

local function test_two_slots_pass()
  check.equal(#diagnose(
      "local function f(): Rec | nil, string\n  return nil\nend\n"), 0,
    "the shape the whole doctrine asks for must never be flagged")
end
test_two_slots_pass()

local function test_infallible_tuple_passes()
  check.equal(#diagnose(
      "local function partition(s: string): string, string, string\n" ..
      "  return s, s, s\nend\n"), 0,
    "no slot of an infallible triple could be an error (string.partition)")
end
test_infallible_tuple_passes()

local function test_generic_slot_one_passes()
  check.equal(#diagnose(
      "local function must<T>(v: T | nil, e?: string, ...: any): T, string, any\n" ..
      "  return v, e\nend\n"), 0,
    "a type variable in slot 1 does not itself admit nil")
end
test_generic_slot_one_passes()

local function test_any_admits_nil()
  check.equal(#diagnose(
      "local function f(): any, integer, integer\n  return nil\nend\n"), 1,
    "`any` admits nil, which is how query_value's error hid in slot 3")
end
test_any_admits_nil()

local function test_record_field_signature_is_checked()
  check.equal(#diagnose(
      "local record M\n  find: function(d: string): {string} | nil, string, {string}\n" ..
      "end\nreturn M\n"), 1,
    "a module record's mirror declares the same contract")
end
test_record_field_signature_is_checked()

-- A foreign shape needs no marker: a cosmo binding's tuple is declared
-- once in the generated .d.tl, which lint exempts by position, and code
-- that needs to NAME it refers to that type instead of retyping it. A
-- varargs return is the other way out, for an arity that genuinely is
-- not the caller's to know.

local function test_varargs_return_is_one_slot()
  check.equal(#diagnose(
      "local record M\n  probe: function(any): any...\nend\nreturn M\n"), 0,
    "`any...` declares one slot, not an open-ended tuple")
end
test_varargs_return_is_one_slot()

local function test_a_comment_never_exempts()
  check.equal(#diagnose(
      "local record M\n  -- returns: a reason someone typed\n" ..
      "  f: function(): any, string, integer\nend\nreturn M\n"), 1,
    "there is no comment escape hatch; the shape has to change")
end
test_a_comment_never_exempts()

local function test_body_is_not_read_as_more_slots()
  -- The return list ends at the first token that is not a comma: a
  -- body statement starting with an identifier used to be read as
  -- slot 2, and a table constructor as slot 3.
  check.equal(#diagnose(
      "local function f(): Rec | nil\n  print(1)\n  g(2)\n  return nil\nend\n"), 0,
    "the function BODY is not part of its return list")
end
test_body_is_not_read_as_more_slots()

local function test_signature_inside_a_string_is_not_a_signature()
  check.equal(#diagnose(
      "local src = [[local function f(): any, boolean, string end]]\n" ..
      "return src\n"), 0,
    "token-exact: a signature quoted in a fixture is not a declaration")
end
test_signature_inside_a_string_is_not_a_signature()

local function test_bare_function_type_does_not_adopt_a_later_signature()
  -- `handler: function` has no parameter list of its own; scanning
  -- forward for one would find the NEXT declaration's.
  check.equal(#diagnose(
      "local record M\n  handler: function\n" ..
      "  f: function(): any, boolean, string\nend\nreturn M\n"), 1,
    "exactly one diagnostic, and it belongs to f")
end
test_bare_function_type_does_not_adopt_a_later_signature()

local function test_parenthesized_return_list()
  check.equal(#diagnose(
      "local record M\n  visit: function(v: function(): (Act ...)): Rec | nil, string\n" ..
      "end\nreturn M\n"), 0,
    "a parenthesized callback return list must not leak into the outer one")
end
test_parenthesized_return_list()

local function test_multi_line_return_list_is_one_list()
  check.equal(slots_reported(
      "local function f(d: string): Rec | nil,\n    string, {string}\n" ..
      "  return nil\nend\n"), 3,
    "a wrapped return list is still one list")
end
test_multi_line_return_list_is_one_list()

local function test_fallible_callback_parameter_is_not_a_return_list()
  -- The comma after the callback's two-slot return list separates the
  -- enclosing PARAMETER list: `acc` is the next parameter, not slot 3.
  local diags = diagnose(
    "local function visit(fn: function(e: Entry): boolean | nil, string," ..
    " acc: {string}): integer\n  return 0\nend\n")
  check.equal(#diags, 0,
    "a parameter after a fallible callback type is not a third slot")
end
test_fallible_callback_parameter_is_not_a_return_list()

local function test_optional_parameter_after_fallible_callback()
  local diags = diagnose(
    "local function visit(fn: function(e: Entry): boolean | nil, string," ..
    " acc?: {string})\nend\n")
  check.equal(#diags, 0,
    "an optional `name?:` parameter after a fallible callback is not a slot")
end
test_optional_parameter_after_fallible_callback()

local function test_callback_own_three_slots_still_flagged()
  -- The disambiguation must not exempt a genuinely over-wide callback:
  -- three type-only slots carry no `name:` and still count.
  local diags = diagnose(
    "local function visit(fn: function(e: Entry): boolean | nil, string," ..
    " integer)\nend\n")
  check.equal(#diags, 1,
    "a callback declaring three return slots is still over-wide")
end
test_callback_own_three_slots_still_flagged()

local function test_message_names_the_fix()
  local diags = diagnose(
    "local function f(): any, boolean, string\n  return nil\nend\n")
  check.equal(#diags, 1)
  local message = diags[1].message
  check.truthy(message:find("local v, err = f()", 1, true),
    "the message must show the call shape that cannot reach slot 3")
  check.truthy(message:find(".d.tl", 1, true),
    "the message must point at where a foreign shape is already declared")
end
test_message_names_the_fix()
