--- The records the new checker ([`lang.check`]) infers for a table literal of named items with no type to check it
--- against: a field for each item, of the type of its value, `mut` where the program writes it through the local that
--- holds the literal. Such a record is below a declared record of the same fields, joins with another, and reads as a
--- map of strings to its fields.
local Array = require("cosmic.array")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

--- Checks that `source` has exactly the errors `codes` (space separated), and that the first says `msg` and, where
--- given, has the fix `fix`.
local function refused(source: string, codes: string, msg?: string, fix?: string)
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source)
  local first = Array.at(r.errors, 1)
  if msg ~= nil then
    assert(first.msg:find(msg, 1, true) ~= nil, first.msg .. "\nwanted " .. msg)
  end
  if fix ~= nil then
    assert(first.fix:find(fix, 1, true) ~= nil, first.fix .. "\nwanted " .. fix)
  end
end

--- Checks that `source` has no error.
local function accepted(source: string)
  local r = Programs.run(source)
  local first = r.errors[1]
  assert(#r.before == 0 and first == nil, table.concat(r.before, " ") .. (if first ~= nil then first.msg else "" end) ..
      " in\n" .. source)
end

--- The type `name` is shown as in `source`.
local function typed(source: string, name: string, display: string)
  local got = Programs.type_of(source, name)
  assert(got == display, name .. " is " .. got .. ", wanted " .. display)
end

-- the record -------------------------------------------------------------------------------------------------

local function test_a_literal_of_named_items_is_a_record_of_its_fields()
  typed("local p = { x = 1, name = \"a\", ok = true }\n", "p", "{ name: string, ok: boolean, x: integer }")
  accepted("local p = { x = 1, name = \"a\" }\nlocal n: integer = p.x\nlocal s: string = p.name\n")
  -- values of different types are fields, not a map that has no common type
  accepted("local p = { x = 1, f = function(n: integer): integer return n end }\nlocal r: integer = p.f(p.x)\n")
  -- a literal inside one is a record of its own
  typed("local p = { at = { x = 1 } }\n", "p", "{ at: { x: integer } }")
end

local function test_a_field_is_mut_where_the_program_writes_it_through_its_local()
  typed("local box = { value = 0 }\nlocal function bump()\n  box.value = box.value + 1\nend\n", "box",
    "{ mut value: integer }")
  typed("local p = { at = { x = 1 }, n = 0 }\np.at.x = 2\n", "p", "{ at: { mut x: integer }, n: integer }")
  accepted("local box = { value = 0 }\nbox[\"value\"] = 1\n")
  -- a write through another name finds the field fixed, and says how to write it
  refused("local p = { x = 1 }\nlocal q = p\nq.x = 2\n", "field_fixed",
    "the field `x` of `{ x: integer }`, a record inferred for a literal, is fixed",
    "write it through that local")
end

local function test_a_field_the_literal_lacks_is_refused_with_a_fix()
  refused("local p = { x = 1 }\np.y = 2\n", "field_unknown",
    "`{ x: integer }`, the record inferred for a literal, has no field `y`", "give `y` in the literal (`y = ...`)")
  refused("local p = { x = 1 }\nlocal v = p.y\n", "field_unknown", "has no field `y`")
end

local function test_a_field_that_says_no_type_is_refused()
  refused("local p = { x = nil }\n", "literal_needs_type", "the field `x` of this literal is `nil`")
  refused("local function f<T>(v: T)\n  local p = { v = v }\nend\n", "literal_needs_type", "a type parameter")
  -- a generic function is a value of a closed type
  accepted("local function id<T>(v: T): T\n  return v\nend\nlocal p = { id = id }\nlocal n: integer = p.id(1)\n")
end

-- a declared record ------------------------------------------------------------------------------------------

local POINT <const> = "local record Point\n  x: integer\n  y: integer\n  label?: string\nend\n" ..
  "local function norm(p: Point): integer\n  return p.x + p.y\nend\n"

local function test_an_inferred_record_is_below_a_record_of_its_fields()
  accepted(POINT .. "local p = { x = 1, y = 2 }\nlocal n = norm(p)\n")
  accepted(POINT .. "local p = { x = 1, y = 2, label = \"a\" }\nlocal q: Point = p\n")
  accepted(POINT .. "local ps = { { x = 1, y = 2 }, { x = 3, y = 4 } }\nlocal all: {Point} = ps\n")
  refused(POINT .. "local p = { x = 1 }\nlocal n = norm(p)\n", "not_assignable", "has no field `y: integer`",
    "give `y` in the literal as `Point` declares it")
  refused(POINT .. "local p = { x = 1, y = 2, z = 3 }\nlocal n = norm(p)\n", "not_assignable", nil,
    "remove `z`, which `Point` has no field of")
  refused(POINT .. "local p = { x = \"a\", y = 2 }\nlocal n = norm(p)\n", "not_assignable", "but not as `x: integer`")
end

local function test_a_mut_field_of_the_record_takes_exactly_its_type()
  local scale = "local record Scale\n  mut by: number\nend\n"
  refused(scale .. "local s = { by = 1 }\nlocal t: Scale = s\n", "not_assignable", "but not as `mut by: number`")
  accepted(scale .. "local s = { by = 1.5 }\nlocal t: Scale = s\n")
end

local function test_a_class_value_is_made_by_a_literal_written_against_it()
  refused("local class C\n  n: integer\nend\nlocal t = { n = 0 }\nlocal c: C = t\n", "not_assignable", nil,
    "write the literal against `C` where it is made")
end

local function test_an_inferred_record_conforms_to_an_interface_of_its_fields()
  accepted("local interface Sized\n  size: integer\nend\nlocal function size_of(s: Sized): integer\n  return s.size\nend\n" ..
      "local box = { size = 3 }\nlocal n = size_of(box)\n")
end

-- joins and maps ---------------------------------------------------------------------------------------------

local function test_two_inferred_records_join_to_one_of_the_fields_of_each()
  typed("local rows = { { x = 1 }, { x = 2, y = \"a\" } }\n", "rows", "mut {{ x: integer, y: string? }}")
  typed("local b = true\nlocal p = if b then { x = 1 } else { x = 2 } end\n", "p", "{ x: integer }")
  refused("local rows = { { x = 1 }, { x = \"a\" } }\n", "arms_differ")
end

local function test_an_inferred_record_reads_as_a_map_of_strings_to_its_fields()
  accepted("local env = { HOME = \"/h\", USER = \"u\" }\nlocal function each(m: {string: string})\nend\neach(env)\n")
  accepted("local counts = { a = 1, b = 2 }\nlocal total = 0\nfor _, n in pairs(counts) do\n  total = total + n\nend\n")
  accepted("local colors = { red = 1, blue = 2 }\nlocal function code(name: string): integer\n" ..
      "  return colors[name] or 0\nend\n")
  -- a write through the map would add a key or change a field's type
  refused("local env = { HOME = \"/h\" }\nlocal function set(m: mut {string: string})\nend\nset(env)\n", "view_as_mut")
  refused("local env = { HOME = 1 }\nlocal function each(m: {string: string})\nend\neach(env)\n", "not_assignable")
end
