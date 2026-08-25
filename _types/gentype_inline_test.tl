#!/usr/bin/env cosmic
--- Tests for the inline table forms gentype renders as Teal arrays: the
--- positional struct, a list of them, and the two shapes that must keep
--- falling through to the caller's `any`.

local inline = require("_types.gentype_inline")

-- The stand-in for gentype_render's convert_type: enough of the real
-- mapping to tell the members of a positional struct apart, with no
-- dependency on the renderer's module-scoped state. It recurses through
-- inline_array the way the real one does, which is what makes a list of
-- positional structs nest instead of flattening to `{any}`.
local convert: function(t: string): string
function convert(t: string): string
  local nested = inline.inline_array(t, convert)
  if nested then
    return nested
  end
  if t == "integer" or t == "string" or t == "number" or t == "boolean" then
    return t
  end
  return "any"
end

-- cosmo.ParseParams is annotated `{ [1]: string, [2]: string? }[]`: a list of
-- pairs whose second element may be absent. Both elements are strings, so the
-- pair is a string array and the list is an array of those.
local function test_a_list_of_positional_structs_is_a_nested_array()
  local t = inline.inline_array("{ [1]: string, [2]: string? }[]", convert)
  assert(t == "{{string}}", "got: " .. tostring(t))
end
test_a_list_of_positional_structs_is_a_nested_array()

local function test_a_bare_positional_struct_is_an_array()
  local t = inline.inline_array("{ [1]: string, [2]: string? }", convert)
  assert(t == "{string}", "got: " .. tostring(t))

  local ints = inline.inline_array("{ [1]: integer, [2]: integer, [3]: integer }", convert)
  assert(ints == "{integer}", "got: " .. tostring(ints))
end
test_a_bare_positional_struct_is_an_array()

-- Teal has no tuple type, so a struct whose members disagree has no honest
-- array rendering; declining it leaves the caller's `any` in place.
local function test_mixed_members_are_declined()
  local t = inline.inline_array("{ [1]: string, [2]: integer }", convert)
  assert(t == nil, "got: " .. tostring(t))
end
test_mixed_members_are_declined()

-- A named inline struct is a record shape, not an array, and stays declined
-- whether or not it is wrapped in a list.
local function test_named_inline_structs_are_declined()
  local t = inline.inline_array("{ name: string }", convert)
  assert(t == nil, "got: " .. tostring(t))

  local listed = inline.inline_array("{ name: string }[]", convert)
  assert(listed == "{any}", "a list of them is an array of what convert says: "
    .. tostring(listed))
end
test_named_inline_structs_are_declined()

-- Nothing that is not an inline table is this module's business.
local function test_other_types_are_declined()
  assert(inline.inline_array("string", convert) == nil, "a scalar")
  assert(inline.inline_array("string[]", convert) == nil, "a plain array")
  assert(inline.inline_array("fun(a: string): string", convert) == nil, "a function")
end
test_other_types_are_declined()

print("all gentype inline table tests passed")
