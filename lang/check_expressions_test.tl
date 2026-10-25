--- The second part of the new checker's expressions ([`lang.check`]): a method called through a union of declarations,
--- an `is` of a type the value cannot have, and the arguments a call expands from its last one (the `T...` it ends in
--- and the literals before it).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local function has(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

--- The codes of checking `source`, which has no error of the parser, the scopes or the lowering.
local function codes_of(source: string): string
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  return Programs.codes(r)
end

--- Checks that `source` has exactly the errors `codes` (space separated), and that the first says `msg`.
local function refused(source: string, codes: string, msg?: string, fix?: string)
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" ..
      (r.errors[1] ~= nil and r.errors[1].msg or ""))
  if msg ~= nil then
    assert(has(r.errors[1].msg, msg), r.errors[1].msg .. "\nwanted " .. msg)
  end
  if fix ~= nil then
    assert(has(r.errors[1].fix, fix), r.errors[1].fix .. "\nwanted " .. fix)
  end
end

-- a method called through a union ------------------------------------------------------------------------

local SHAPES <const> = [[
local class Circle
  r: number
  function area(self): number
    return self.r
  end
  function scale(self, by: number): number
    return by
  end
end
local class Square
  side: number
  function area(self): number
    return self.side
  end
  function scale(self, by: number): number
    return by
  end
end
]]

local function test_a_method_every_member_declares_alike_is_called_through_the_union()
  local r = Programs.run(SHAPES .. [[
local function total(s: Circle | Square): number
  local a: number = s:area()
  local b = s:scale(2)
  return a + b
end
]])
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r) .. (r.errors[1] ~= nil and r.errors[1].msg or ""))
  assert(Types.display(Programs.var(r, "b")) == "number")
end

local function test_the_arguments_and_the_result_of_a_call_through_a_union_are_checked_against_the_common_method()
  local head = SHAPES .. "local function f(s: Circle | Square)\n"
  refused(head .. "  local n: string = s:area()\nend\n", "not_assignable", "`s:area()` is `number`, where `string` is wanted")
  refused(head .. "  local n = s:scale(\"x\")\nend\n", "not_assignable", "as argument 1 of `s:scale`")
  refused(head .. "  local n = s:scale()\nend\n", "arity", "`s:scale` takes 1 argument, but 0 are given")
  assert(codes_of(head .. "  local n = s:scale(1, 2)\nend\n") == "arity")
end

local function test_a_method_the_members_declare_differently_is_reported_and_says_to_narrow_first()
  local other = "local class Tri\n  side: integer\n  function area(self): integer\n    return self.side\n  end\n" ..
    "  function scale(self, by: integer): number\n    return 1\n  end\nend\n"
  local head = SHAPES .. other .. "local function f(s: Circle | Tri)\n"
  refused(head .. "  local a = s:area()\nend\n", "not_callable",
    "calls the method `area` of each member of `Circle | Tri`, and ",
    "narrow the value to one member first")
  refused(head .. "  local a = s:scale(1)\nend\n", "not_callable", " declare it differently: `function(Tri, integer): number` and `function(Circle, number): number`")
  -- the arguments are still checked, so that what is in them is reported once
  assert(codes_of(head .. "  local a = s:scale(1 + \"x\")\nend\n") == "not_callable operand_type")
end

local function test_a_member_without_the_method_is_told_to_narrow_first()
  local head = SHAPES .. "local class Dot\n  x: number\nend\nlocal function f(s: Circle | Dot)\n"
  refused(head .. "  local a = s:area()\nend\n", "field_unknown", "`area` is not a field of `Dot`, a member of `Circle | Dot`",
    "narrow the value to the member that has it")
end

local function test_a_generic_member_is_compared_with_its_type_arguments_put_in()
  local box = "local class Box<T>\n  value: T\n  function get(self): T\n    return self.value\n  end\nend\n"
  refused(box .. "local function f(b: Box<integer> | Box<string>)\n  local v = b:get()\nend\n", "not_callable",
    "declare it differently")
  assert(codes_of(box .. "local function f(b: Box<integer> | Box<integer>)\n  local v: integer = b:get()\nend\n") == "")
end

local function test_a_method_of_an_interface_is_called_through_a_union_of_it_and_a_class_that_lists_it()
  local source = "local interface Sized\n  size: function(self: Sized): integer\nend\n" ..
    "local class Bag is Sized\n  n: integer\n  function size(self): integer\n    return self.n\n  end\nend\n"
  assert(codes_of(source .. "local function f(s: Sized | Bag): integer\n  return s:size()\nend\n") == "")
end

local function test_an_optional_union_is_told_it_may_be_nil_and_the_method_is_still_typed()
  local head = SHAPES .. "local function f(s: (Circle | Square)?)\n"
  refused(head .. "  local a: number = s:area()\nend\n", "nil_not_allowed", "`s` is `(Circle | Square)?`, so it may be nil")
end

-- an `is` of a type the value cannot have ----------------------------------------------------------------

local TESTED <const> = [[
local interface Shape
  area: function(self: Shape): number
end
local class Circle is Shape
  r: number
  function area(self): number
    return self.r
  end
end
local class Plain
  n: integer
end
local enum Color "red" "green" end
]]

local function test_a_test_of_a_type_the_value_cannot_have_is_always_false()
  local head = TESTED .. "local function f(v: Circle, p: Plain, s: Shape, n: integer, t: string?, u: integer | string)\n"
  refused(head .. "  local a = v is Plain\nend\n", "is_disjoint", "`v is Plain` is always false: `v` is `Circle`, and no value of it is `Plain`",
    "this test is always false")
  refused(head .. "  local a = s is Plain\nend\n", "is_disjoint", "`s` is `Shape`")
  refused(head .. "  local a = n is string\nend\n", "is_disjoint", "`n` is `integer`, and no value of it is `string`")
  refused(head .. "  local a = n is nil\nend\n", "is_disjoint")
  refused(head .. "  local a = n is Color\nend\n", "is_disjoint")
  refused(head .. "  local a = t is integer\nend\n", "is_disjoint", "`t` is `string?`")
  refused(head .. "  local a = u is boolean\nend\n", "is_disjoint")
  refused(head .. "  local a = p is Circle\nend\n", "is_disjoint")
end

local function test_a_test_the_value_may_pass_stands()
  local head = TESTED .. "local function f(v: Circle, s: Shape, n: number, t: string?, u: integer | string, c: string, a: any)\n"
  for _, use in ipairs({
      "s is Circle", "v is Circle", "n is integer", "t is string", "t is nil", "u is string", "u is integer",
      "c is Color", "a is Plain", "a is integer",
  }) do
    assert(codes_of(head .. "  local x = " .. use .. "\nend\n") == "", use .. ": " .. codes_of(head .. "  local x = " .. use .. "\nend\n"))
  end
end

local function test_a_test_of_a_type_variable_stands_since_the_code_around_may_make_it_anything()
  assert(codes_of("local function f<T>(v: T): boolean\n  return v is string\nend\n") == "")
end

local function test_a_test_the_rules_refuse_is_reported_once_for_that()
  local head = "local record R\n  n: integer\nend\nlocal function f(n: integer)\n"
  refused(head .. "  local a = n is R\nend\n", "is_on_record", "a record leaves nothing to test")
  refused(head .. "  local a = n is {integer}\nend\n", "is_on_record")
end

-- the values the last argument of a call expands to --------------------------------------------------------

local EXPANDED <const> = [[
local ints: function(): integer... = function() end
local strs: function(): string... = function() end
local function take(a: string, b: integer): string
  return a
end
local function maybe(a: string, b?: integer): string
  return a
end
local function every(a: string, ...: integer): string
  return a
end
local function one(a: integer): integer
  return a
end
local record Box
  n: integer
end
local box: Box = { n = 1 }
]]

local function test_the_tail_a_last_argument_ends_in_is_checked_against_the_parameters_it_fills()
  refused(EXPANDED .. "local x = take(\"a\", ints())\n", "nil_not_allowed",
    "`ints()` ends in `integer...`, so argument 2 of `take` may be missing, where `integer` is wanted",
    "varargs end in nil")
  refused(EXPANDED .. "local x = take(\"a\", strs())\n", "not_assignable", "`strs()` is `string`, where `integer` is wanted as argument 2 of `take`")
  refused(EXPANDED .. "local x = take(ints())\n", "not_assignable", "as argument 1 of `take`")
  assert(codes_of(EXPANDED .. "local x = maybe(\"a\", ints())\n") == "")
  assert(codes_of(EXPANDED .. "local x = maybe(\"a\", strs())\n") == "not_assignable")
  assert(codes_of(EXPANDED .. "local x = every(\"a\", ints())\n") == "")
  refused(EXPANDED .. "local x = every(\"a\", strs())\n", "not_assignable", "as argument 2 of `every`")
end

local function test_a_tail_past_every_parameter_fills_the_rest_parameter_and_the_values_known_are_still_checked()
  refused(EXPANDED .. "local x = every(\"a\", 1, strs())\n", "not_assignable", "as argument 3 of `every`")
  refused(EXPANDED .. "local x = take(1, ints())\n", "not_assignable nil_not_allowed", "as argument 1 of `take`")
  assert(codes_of(EXPANDED .. "local x = every(\"a\", 1, ints())\n") == "")
end

local function test_a_vararg_fills_the_parameters_after_the_values_before_it_the_same_way()
  assert(codes_of(EXPANDED .. "local function f(...: integer): string\n  return take(\"a\", ...)\nend\n") == "nil_not_allowed")
  assert(codes_of(EXPANDED .. "local function f(...: integer): string\n  return maybe(\"a\", ...)\nend\n") == "")
  assert(codes_of(EXPANDED .. "local function f(...: integer): string\n  return every(\"a\", ...)\nend\n") == "")
  assert(codes_of(EXPANDED .. "local function f(...: string): string\n  return every(\"a\", ...)\nend\n") == "not_assignable")
end

local function test_a_tail_in_a_method_call_counts_its_arguments_after_the_receiver()
  local head = EXPANDED .. "local record Sink\n  put: function(Sink, string, integer)\nend\n" ..
    "local sink: Sink = { put = function(_s: Sink, _a: string, _b: integer) end }\n"
  refused(head .. "sink:put(\"a\", ints())\n", "nil_not_allowed", "so argument 2 of `sink:put` may be missing")
  refused(head .. "sink:put(\"a\", strs())\n", "not_assignable", "as argument 2 of `sink:put`")
  assert(codes_of(head .. "sink:put(\"a\", 1, ints())\n") == "")
  refused(head .. "sink:put(\"a\", 1, 2, ints())\n", "arity", "`sink:put` takes 2 arguments, but 3 are given")
end

local function test_a_value_known_past_the_parameters_is_a_surplus_argument_whatever_the_tail_gives()
  local mixed = "local mixed: function(): integer, integer, integer... = function() return 1, 2 end\n"
  refused(EXPANDED .. mixed .. "local x = one(mixed())\n", "arity", "`one` takes 1 argument, but 2 are given")
  assert(codes_of(EXPANDED .. "local x = one(ints())\n") == "nil_not_allowed")
  assert(codes_of(EXPANDED .. mixed .. "local x = every(\"a\", mixed())\n") == "")
end

local function test_an_expanding_last_argument_leaves_the_literals_before_it_to_the_overload_taken()
  local head = "local count: function(): integer... = function() end\n"
  -- the function literal takes its parameter's type from the overload taken
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", function(c) return c end, count())\n") == "")
  -- and is held to it
  refused(head .. "local r = (\"x\"):gsub(\"a\", function(c: integer): string return \"\" end, count())\n", "not_assignable",
    "is `function(integer): string`, where `function(string): string` is wanted as argument 2")
  -- a literal that fits no overload fails the call
  refused(head .. "local r = (\"x\"):gsub(\"a\", 1, count())\n", "overload_none", "no overload of `(\"x\"):gsub`")
  -- the tail is part of what an overload accepts: a string fills the count, which an integer is
  local strs = "local strs: function(): string... = function() end\n"
  refused(strs .. "local r = (\"x\"):gsub(\"a\", \"b\", strs())\n", "overload_none", "no overload of",
    "argument 3 is filled by `string...`, where `integer?` is wanted")
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", \"b\", count())\n") == "")
end

local function test_a_table_literal_before_an_expanding_argument_is_checked_against_the_overload_taken()
  local head = "local ints: function(): integer... = function() end\n"
  assert(codes_of(head .. "local x = Over.put({ n = 1 }, ints())\n") == "")
  refused(head .. "local x = Over.put({ n = \"s\" }, ints())\n", "not_assignable", "as the field `n` of `Opts`")
  refused(head .. "local x = Over.put({}, ints())\n", "literal_missing", "this literal of `Opts` leaves out `n`")
  assert(codes_of(head .. "local x = Over.put(\"a\", ints())\n") == "")
end

local function test_a_function_literal_fits_the_overload_that_takes_its_arguments_whatever_the_order()
  -- the overload with more parameters comes first: a literal with fewer cannot be called with all of them
  local more = "More.run(function(x: string, y: string): string return x .. y end)\n" ..
    "More.run(function(x: string): string return x end)\n" ..
    "More.run(function(): string return \"\" end)\n" ..
    "More.run(function(x) return x end)\n"
  assert(codes_of(more) == "")
  -- the one with fewer comes first: a literal with more parameters would require an argument it is never given
  local fewer = "Fewer.run(function(x: string): string return x end)\n" ..
    "Fewer.run(function(x: string, y: string): string return x .. y end)\n"
  assert(codes_of(fewer) == "")
  -- and a literal no overload takes fails the call, listing why
  refused("Fewer.run(function(x: string, y: string, z: string): string return x end)\n", "overload_none",
    "no overload of `Fewer.run`")
end

-- a method called on an enum --------------------------------------------------------------------------------

local KIND <const> = "local enum Kind\n  \"a\"\n  \"b\"\nend\nlocal enum Other\n  \"c\"\nend\nlocal k: Kind = \"a\"\n"

local function test_a_method_called_on_an_enum_is_a_function_of_string()
  local r = Programs.run(KIND .. "local x = k:upper()\nlocal y = k:sub(1, 1)\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  assert(Types.display(Programs.var(r, "x")) == "string")
  assert(Types.display(Programs.var(r, "y")) == "string")
  -- the result is a string, never the enum, so it is not a place for the enum
  assert(codes_of(KIND .. "local x: Kind = k:upper()\n") == "not_assignable")
  assert(codes_of(KIND .. "local x = k:sub(\"a\")\n") == "not_assignable")
  refused(KIND .. "local x = k:nosuch()\n", "field_unknown", "`Kind` is an enum, a string with no method `nosuch`")
end

local function test_a_method_called_on_a_union_of_enums_or_of_an_enum_and_a_string()
  local r = Programs.run(KIND .. "local function f(u: Kind | Other, v: Kind | string): string\n" ..
    "  local s = u:upper()\n  return s .. v:sub(1, 1)\nend\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  assert(codes_of(KIND .. "local function f(u: Kind | Other)\n  local x: Kind = u:upper()\nend\n") == "not_assignable")
  -- a member that is not text has no function of string, and one with a function of its own differs from it
  local mixed = KIND .. "local record R\n  n: integer\nend\nlocal function f(u: Kind | R)\n  local x = u:upper()\nend\n"
  assert(codes_of(mixed) == "field_unknown")
  local own = KIND .. "local class C\n  function upper(self): string\n    return \"\"\n  end\nend\n" ..
    "local function f(u: Kind | C)\n  local x = u:upper()\nend\n"
  refused(own, "not_callable", "declare it differently: `function(C): string` and `function(string): string`")
  local mine = KIND .. "local record M\n  upper: function(self: M): string\nend\n" ..
    "local function f(u: Kind | M)\n  print(u:upper())\nend\n"
  refused(mine, "not_callable", "declare it differently: `function(M): string` and `function(string): string`")
end

local function test_a_member_of_an_enum_is_not_read_indexed_or_written()
  refused(KIND .. "local x = k.upper\n", "field_unknown", "whose values have no fields", "v:upper(...)")
  refused(KIND .. "local x = k.x\n", "field_unknown", "`x` is not one")
  refused(KIND .. "local x = k.upper(k)\n", "field_unknown")
  refused(KIND .. "local function f(u: Kind | Other)\n  local x = u.upper\nend\n", "field_unknown",
    "`upper` is not a field of `Other`, an enum and a member of `Kind | Other`",
    "call a function of `string` on it, `v:upper(...)`, or narrow the value to the member that has it (`x is T`)")
  assert(codes_of(KIND .. "local m: Kind = \"a\"\nm.x = \"b\"\n") ~= "")
  assert(codes_of(KIND .. "local x = k[1]\n") ~= "")
  assert(codes_of(KIND .. "local x = k[\"upper\"]\n") ~= "")
end

--- `format` called as a method of a text is typed as `string.format` is: the conversions of a literal format fix the
--- arguments it takes, so `("x"):format("y")` is refused because the format `x` has no conversion (it is no mistyped
--- method), and a format with one conversion takes one argument by either spelling.
local function test_format_called_as_a_method_takes_the_arguments_its_format_asks_for()
  refused('local a = ("x"):format("y")\nprint(a)\n', "arity", "takes 0 arguments, but 1 is given")
  refused('local a = string.format("x", "y")\nprint(a)\n', "arity", "takes 1 argument, but 2 are given")
  refused('local s: string = "x"\nlocal a = s:format("y")\nprint(a)\n', "arity", "takes 0 arguments, but 1 is given")
  assert(codes_of('local a = ("x%s"):format("y")\nprint(a)\n') == "")
  assert(codes_of('local s: string = "x%s"\nlocal a = s:format("y")\nprint(a)\n') == "")
  assert(codes_of('local a = string.format("x%s", "y")\nprint(a)\n') == "")
end
