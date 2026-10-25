--- Tests of tagged unions in [`lang.check`] ("tagged unions" in doc/plans/strict-teal.md): a union of records whose
--- one field has an enum in each member, no value of which is in two members, is told apart by `==` on that field, and a
--- chain of tests that covers every member ends a function. Every program the checker takes is also run as the Lua [`lang.codegen`]
--- writes, with each narrowed read checked against the members the tag selected ([`Programs.execute`]).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local HEAD <const> = [[
local enum Circle_kind "circle" end
local enum Square_kind "square" end
local enum Line_kind "line" end
local record Circle
  kind: Circle_kind
  radius: integer
end
local record Square
  kind: Square_kind
  side: integer
end
local record Line
  kind: Line_kind
  length: integer
end
local type Shape = Circle | Square
local type Figure = Circle | Square | Line
local function circle(): Shape
  local c: Circle = { kind = "circle", radius = 3 }
  return c
end
local function square(): Shape
  local s: Square = { kind = "square", side = 4 }
  return s
end
local function line(): Figure
  local l: Line = { kind = "line", length = 5 }
  return l
end
local record Holder
  item: Shape
  mut moving: Shape
end
local function held(): Holder
  return { item = circle(), moving = square() }
end
]]

--- The codes of checking `body` after the head.
local function codes_of(body: string, head?: string): string
  local r = Programs.run((head or HEAD) .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  return Programs.codes(r)
end

--- Checks that `body` is taken, runs with every narrowed read checked, and prints `want` (joined by commas).
local function stands(body: string, want: string, head?: string)
  local x = Programs.execute((head or HEAD) .. body, true)
  assert(#x.run.before == 0, table.concat(x.run.before, " ") .. " in\n" .. body)
  assert(x.ran, Programs.codes(x.run) .. " in\n" .. body)
  assert(x.fault == nil, tostring(x.fault) .. " in\n" .. x.lua)
  assert(table.concat(x.printed, ",") == want, table.concat(x.printed, ",") .. ", wanted " .. want .. " in\n" .. body)
end

--- Checks that `body` is refused with exactly `codes`.
local function refused(body: string, codes: string, head?: string)
  local got = codes_of(body, head)
  assert(got == codes, "wanted " .. codes .. ", got " .. got .. " in\n" .. body)
end

--- The type of the last variable called `name` after checking `body`.
local function type_of(body: string, name: string, head?: string): string
  local r = Programs.run((head or HEAD) .. body)
  assert(#r.before == 0 and Programs.codes(r) == "", table.concat(r.before, " ") .. Programs.codes(r) .. " in\n" .. body)
  local found: Types.Type? = nil
  for _, v in ipairs(r.scoped.list) do
    if v.name == name then
      found = r.result.vars[v.id] or found
    end
  end
  assert(found ~= nil, "no variable " .. name)
  return Types.display(found)
end

local function test_a_test_of_the_tag_selects_the_member_in_the_branch_it_holds_and_the_others_in_the_other()
  stands("local function area(s: Shape): integer\n  if s.kind == \"circle\" then\n    return s.radius * 3\n  else\n    return s.side * s.side\n  end\nend\n" ..
      "print(area(circle()), area(square()))\n", "9\t16")
  assert(type_of("local s = circle()\nif s.kind == \"circle\" then\n  local seen = s\nend\n", "seen") == "Circle")
  assert(type_of("local s = square()\nif s.kind ~= \"circle\" then\n  local seen = s\nend\n", "seen") == "Square")
  assert(type_of("local s = line()\nif s.kind ~= \"line\" then\n  local seen = s\nend\n", "seen") == "Circle | Square")
  -- The literal may stand on the left.
  stands("local function side(s: Shape): integer\n  if \"square\" == s.kind then\n    return s.side\n  end\n  return 0\nend\nprint(side(square()))\n", "4")
  refused("local function wrong(s: Shape): integer\n  return s.radius\nend\n", "field_unknown")
  refused("local function wrong(s: Shape): integer\n  if s.kind == \"circle\" then\n    return s.side\n  end\n  return 0\nend\n", "field_unknown")
  refused("local function wrong(s: Shape): integer\n  if s.kind ~= \"circle\" then\n    return s.radius\n  end\n  return 0\nend\n", "field_unknown")
end

local function test_the_tag_of_a_union_reads_as_the_union_of_its_enums()
  assert(type_of("local s = circle()\nlocal k = s.kind\n", "k") == "Circle_kind | Square_kind")
end

local function test_a_chain_of_tests_that_covers_every_member_ends_a_function_and_one_that_leaves_one_does_not()
  stands("local function size(f: Figure): integer\n  if f.kind == \"circle\" then\n    return f.radius\n  elseif f.kind == \"square\" then\n" ..
      "    return f.side\n  elseif f.kind == \"line\" then\n    return f.length\n  end\nend\nprint(size(line()), size(circle()))\n", "5\t3")
  refused("local function size(f: Figure): integer\n  if f.kind == \"circle\" then\n    return f.radius\n  elseif f.kind == \"square\" then\n" ..
      "    return f.side\n  end\nend\n", "missing_return")
  -- The rest after the tests is the member left, and a branch that ends leaves the rest.
  stands("local function size(f: Figure): integer\n  if f.kind == \"circle\" then\n    return f.radius\n  end\n  if f.kind == \"square\" then\n" ..
      "    return f.side\n  end\n  return f.length\nend\nprint(size(line()))\n", "5")
  assert(type_of("local f = line()\nif f.kind == \"circle\" or f.kind == \"square\" then\n  return\nend\nlocal rest = f\n", "rest") == "Line")
end

local function test_a_test_of_a_tag_in_a_condition_that_combines_tests_narrows_what_each_side_allows()
  stands("local function big(s: Shape): boolean\n  return s.kind == \"circle\" and s.radius > 2\nend\nprint(big(circle()), big(square()))\n", "true\tfalse")
  stands("local function small(s: Shape): boolean\n  return s.kind ~= \"circle\" or s.radius < 2\nend\nprint(small(circle()), small(square()))\n", "false\ttrue")
  refused("local function wrong(s: Shape): boolean\n  return s.kind == \"circle\" or s.radius > 2\nend\n", "field_unknown")
end

local function test_a_tag_of_a_field_of_a_fixed_field_narrows_and_one_that_a_program_can_change_does_not()
  stands("local h = held()\nif h.item.kind == \"circle\" then\n  print(h.item.radius)\nend\n", "3")
  -- A `mut` field may be assigned between the test and the read, so the test narrows nothing.
  refused("local h = held()\nif h.moving.kind == \"square\" then\n  print(h.moving.side)\nend\n", "field_unknown")
  -- A local assigned between them loses what the test showed.
  refused("local s = circle()\nif s.kind == \"circle\" then\n  s = square()\n  print(s.radius)\nend\n", "field_unknown")
  -- A closure made before an assignment does not carry the test into it.
  refused("local s = circle()\nlocal function read(): integer\n  if s.kind == \"circle\" then\n    return s.radius\n  end\n  return 0\nend\n" ..
      "s = square()\nprint(read())\n", "field_unknown")
end

local function test_a_tag_that_is_no_member_of_the_enum_or_a_union_that_is_not_tagged_is_refused()
  refused("local function f(s: Shape): integer\n  if s.kind == \"triangle\" then\n    return 1\n  end\n  return 0\nend\n", "enum_member")
  -- Two members with one tag value are told apart by nothing.
  local r = Programs.run(HEAD .. "local record Dot\n  kind: Circle_kind\n  at: integer\nend\nlocal type Pair = Circle | Dot\n")
  assert(table.concat(r.before, " ") == "untagged_union", table.concat(r.before, " "))
end

local function test_a_member_with_the_tag_value_is_selected_by_a_literal_checked_against_the_union()
  assert(type_of("local s: Shape = { kind = \"square\", side = 2 }\nlocal t = s\n", "t") == "Square")
  stands("local s: Shape = { kind = \"circle\", radius = 2 }\nprint(s.kind)\n", "circle")
  refused("local s: Shape = { kind = \"circle\", side = 2 }\n", "literal_missing literal_unknown")
end

--- Checks that the type of the last variable called `name` after checking `body` is `want`.
local function has_type(body: string, name: string, head: string?, want: string)
  local got = type_of(body, name, head)
  assert(got == want, got .. ", wanted " .. want .. " in\n" .. body)
end

--- Members whose tag enums have several values: `Curved` is "circle" or "oval", `Angular` "square", "rect" or "tri", and
--- `Line` "line" alone.
local MANY <const> = [[
local enum Curved_kind "circle" "oval" end
local enum Angular_kind "square" "rect" "tri" end
local enum Line_kind "line" end
local record Curved
  kind: Curved_kind
  radius: integer
end
local record Angular
  kind: Angular_kind
  side: integer
end
local record Line
  kind: Line_kind
  length: integer
end
local type Round = Curved | Angular
local type Figure = Curved | Angular | Line
local function curved(k: Curved_kind): Figure
  local c: Curved = { kind = k, radius = 3 }
  return c
end
local function angular(k: Angular_kind): Figure
  local a: Angular = { kind = k, side = 4 }
  return a
end
local function line(): Figure
  local l: Line = { kind = "line", length = 5 }
  return l
end
]]

local function test_a_test_of_any_value_of_a_tag_with_several_values_selects_the_member_that_keeps_all_of_them()
  for _, value in ipairs({ "circle", "oval" }) do
    has_type("local f = curved(\"" .. value .. "\")\nif f.kind == \"" .. value .. "\" then\n  local seen = f\nend\n", "seen", MANY, "Curved")
  end
  for _, value in ipairs({ "square", "rect", "tri" }) do
    has_type("local f = line()\nif f.kind == \"" .. value .. "\" then\n  local seen = f\nend\n", "seen", MANY, "Angular")
  end
  stands("local function size(f: Figure): integer\n  if f.kind == \"oval\" then\n    return f.radius\n  elseif f.kind == \"tri\" then\n" ..
      "    return f.side\n  end\n  return 0\nend\nprint(size(curved(\"oval\")), size(angular(\"tri\")), size(line()))\n", "3\t4\t0", MANY)
  -- The literal may stand on the left.
  stands("local function side(f: Figure): integer\n  if \"rect\" == f.kind then\n    return f.side\n  end\n  return 0\nend\n" ..
      "print(side(angular(\"rect\")))\n", "4", MANY)
  -- The member is not the other one's.
  refused("local function wrong(f: Figure): integer\n  if f.kind == \"oval\" then\n    return f.side\n  end\n  return 0\nend\n",
    "field_unknown", MANY)
  refused("local function wrong(f: Figure): integer\n  if f.kind == \"rect\" then\n    return f.radius\n  end\n  return 0\nend\n",
    "field_unknown", MANY)
end

local function test_a_test_against_a_value_removes_a_member_only_where_it_is_the_one_value_the_member_has()
  -- `Line` has the one value, so `~=` removes it: `Round` is left.
  has_type("local f = line()\nif f.kind ~= \"line\" then\n  local seen = f\nend\n", "seen", MANY, "Angular | Curved")
  -- `Curved` may still be "oval", so `~= "circle"` keeps it, and `Angular` and `Line` with it.
  has_type("local f = line()\nif f.kind ~= \"circle\" then\n  local seen = f\nend\n", "seen", MANY, "Angular | Curved | Line")
  has_type("local f = line()\nif f.kind ~= \"tri\" then\n  local seen = f\nend\n", "seen", MANY, "Angular | Curved | Line")
  -- The false edge of `==` is the same as the true edge of `~=`.
  has_type("local f = line()\nif f.kind == \"circle\" then\n  return\nend\nlocal rest = f\n", "rest", MANY, "Angular | Curved | Line")
  has_type("local f = line()\nif f.kind == \"line\" then\n  return\nend\nlocal rest = f\n", "rest", MANY, "Angular | Curved")
  -- The program that removing `Curved` would let through reads a field `oval` does not have.
  refused("local function wrong(f: Figure): integer\n  if f.kind ~= \"circle\" and f.kind ~= \"line\" and f.kind ~= \"square\" then\n" ..
      "    return f.side\n  end\n  return 0\nend\n", "field_unknown", MANY)
  stands("local function length(f: Figure): integer\n  if f.kind ~= \"line\" then\n    return 0\n  end\n  return f.length\nend\n" ..
      "print(length(line()), length(curved(\"oval\")))\n", "5\t0", MANY)
  -- `oval` passes `~= "circle"`, as the member it is.
  stands("local function other(f: Figure): integer\n  if f.kind ~= \"circle\" then\n    return 1\n  end\n  return 0\nend\n" ..
      "print(other(curved(\"oval\")), other(curved(\"circle\")), other(line()))\n", "1\t0\t1", MANY)
end

local function test_a_literal_checked_against_a_union_is_the_member_whose_tag_enum_has_its_value()
  has_type("local f: Figure = { kind = \"oval\", radius = 2 }\nlocal t = f\n", "t", MANY, "Curved")
  has_type("local f: Figure = { kind = \"tri\", side = 2 }\nlocal t = f\n", "t", MANY, "Angular")
  stands("local f: Figure = { kind = \"rect\", side = 2 }\nprint(f.kind)\n", "rect", MANY)
  refused("local f: Figure = { kind = \"oval\", side = 2 }\n", "literal_missing literal_unknown", MANY)
end

local function test_a_value_in_two_members_is_untagged_and_the_tag_of_a_member_is_its_enum_of_values()
  local r = Programs.run(MANY .. "local record Dot\n  kind: Curved_kind\n  at: integer\nend\nlocal type Pair = Curved | Dot\n")
  assert(table.concat(r.before, " ") == "untagged_union", table.concat(r.before, " "))
  -- One shared value among several is enough.
  local enum = Programs.run(MANY .. "local enum Dot_kind \"dot\" \"tri\" end\nlocal record Dot\n  kind: Dot_kind\nend\nlocal type Pair = Angular | Dot\n")
  assert(table.concat(enum.before, " ") == "untagged_union", table.concat(enum.before, " "))
  has_type("local f = line()\nlocal k = f.kind\n", "k", MANY, "Angular_kind | Curved_kind | Line_kind")
end

local function test_an_assert_of_a_test_of_the_tag_narrows_what_follows_it()
  stands("local function area(s: Shape): integer\n  assert(s.kind == \"circle\")\n  return s.radius * 3\nend\nprint(area(circle()))\n", "9")
  stands("local function side(s: Shape): integer\n  assert(s.kind ~= \"circle\")\n  return s.side\nend\nprint(side(square()))\n", "4")
  has_type("local s = line()\nassert(s.kind == \"circle\" or s.kind == \"square\")\nlocal seen = s\n", "seen", nil, "Circle | Square")
  -- With several values, as a test does.
  stands("local function radius(f: Figure): integer\n  assert(f.kind == \"oval\")\n  return f.radius\nend\nprint(radius(curved(\"oval\")))\n", "3", MANY)
  has_type("local f = line()\nassert(f.kind ~= \"circle\")\nlocal seen = f\n", "seen", MANY, "Angular | Curved | Line")
  -- An assert of a test with a message, and one that tests another place.
  stands("local function area(s: Shape): integer\n  assert(s.kind == \"circle\", \"a circle\")\n  return s.radius\nend\nprint(area(circle()))\n", "3")
  refused("local function wrong(s: Shape, t: Shape): integer\n  assert(t.kind == \"circle\")\n  return s.radius\nend\n", "field_unknown")
  -- What `assert` narrowed is lost by an assignment, as a test's is.
  refused("local s = circle()\nassert(s.kind == \"circle\")\ns = square()\nprint(s.radius)\n", "field_unknown")
end
