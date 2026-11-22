--- String literal types: `"circle"` written as a type is the type of that one string, an enum of it alone. An enum is the
--- set of its strings, below an enum or a union of literals that holds each of them, and a test of a place against a
--- string narrows it to the literal where it holds and to the other strings where it fails.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local refused = Programs.says

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

local KIND <const> = "local enum Kind\n  \"a\"\n  \"b\"\nend\n"

-- the type ---------------------------------------------------------------------------------------------------

local function test_a_string_literal_type_holds_that_string_alone()
  accepted("local k: \"a\" = \"a\"\nprint(k)\n")
  refused("local k: \"a\" = \"b\"\nprint(k)\n", "enum_member", "`\"b\"` is not a member of `\"a\"`", "write `\"a\"`")
  typed("local k: \"a\" | \"b\" = \"a\"\n", "k", "\"a\" | \"b\"")
  -- the text is the string, quoted as Lua quotes it
  typed("local k: \"a\\n\" = \"a\\n\"\n", "k", "\"a\\n\"")
end

local function test_a_literal_is_a_string_and_below_an_enum_that_holds_it()
  accepted("local k: \"a\" | \"b\" = \"a\"\nlocal s: string = k\nprint(s)\n")
  accepted(KIND .. "local function f(x: \"a\"): Kind\n  return x\nend\nprint(f(\"a\"))\n")
  -- a union of literals holds an enum of its strings, and an enum is not below one of its strings
  accepted(KIND .. "local function f(k: Kind): \"a\" | \"b\"\n  return k\nend\nprint(f(\"a\"))\n")
  refused(KIND .. "local function f(k: Kind): \"a\"\n  return k\nend\nprint(f(\"a\"))\n", "not_assignable",
    "`k` is `Kind`, where `\"a\"` is wanted")
  refused("local function f(s: string): \"a\"\n  return s\nend\nprint(f(\"a\"))\n", "not_assignable")
end

local function test_a_field_of_a_literal_type_tags_a_union_of_records()
  accepted("local record Circle\n  kind: \"circle\"\n  r: number\nend\nlocal record Square\n  kind: \"square\"\n  s: number\nend\n" ..
      "local type Shape = Circle | Square\nlocal function area(s: Shape): number\n  if s.kind == \"circle\" then\n" ..
      "    return s.r * s.r\n  end\n  return s.s * s.s\nend\nlocal c: Circle = { kind = \"circle\", r = 1 }\nprint(area(c))\n")
  refused("local record R\n  mut kind: \"x\" | \"y\"\nend\nlocal r: R = { kind = \"x\" }\nr.kind = \"z\"\nprint(r.kind)\n",
    "enum_member", "`\"z\"` is not a member of `\"x\" | \"y\"`")
end

-- narrowing --------------------------------------------------------------------------------------------------

local function test_a_test_against_a_string_narrows_the_place_to_its_literal_and_the_rest()
  accepted("local function g(k: \"a\" | \"b\"): integer\n  if k == \"a\" then\n    local s: \"a\" = k\n    return #s\n  end\n" ..
      "  local t: \"b\" = k\n  return #t\nend\nprint(g(\"a\"))\n")
  accepted(KIND .. "local function g(k: Kind): integer\n  if k ~= \"a\" then\n    local t: \"b\" = k\n    return #t\n  end\n" ..
      "  return 0\nend\nprint(g(\"a\"))\n")
  accepted("local function g(s: string): \"a\"?\n  if s == \"a\" then\n    return s\n  end\n  return nil\nend\nprint(g(\"a\"))\n")
  accepted(KIND .. "local function g(k: Kind): integer\n  if k is \"a\" then\n    return 1\n  end\n  local t: \"b\" = k\n" ..
      "  return #t\nend\nprint(g(\"a\"))\n")
end

local function test_a_chain_of_tests_over_every_string_of_an_enum_ends_the_function()
  accepted(KIND .. "local function g(k: Kind): integer\n  if k == \"a\" then\n    return 1\n  elseif k == \"b\" then\n" ..
      "    return 2\n  end\nend\nprint(g(\"a\"))\n")
  refused(KIND .. "local function g(k: Kind): integer\n  if k == \"a\" then\n    return 1\n  end\nend\nprint(g(\"a\"))\n",
    "missing_return")
end

local function test_a_narrowed_literal_is_a_string_again_where_the_program_may_write_another()
  -- a local the program assigns, and the elements and fields of a literal, take `string`
  accepted("local function c(s: string): string\n  if s == \"x\" then\n    local cur = s\n    cur = cur .. \"!\"\n" ..
      "    return cur\n  end\n  return \"\"\nend\nprint(c(\"x\"))\n")
  accepted("local function c(s: string): integer\n  if s == \"x\" then\n    local t = { s }\n    t[#t + 1] = \"y\"\n" ..
      "    return #t\n  end\n  return 0\nend\nprint(c(\"x\"))\n")
  -- a local the program does not assign keeps the literal
  accepted("local function c(s: string): \"x\"?\n  if s == \"x\" then\n    local cur = s\n    return cur\n  end\n" ..
      "  return nil\nend\nprint(c(\"x\"))\n")
end

local function test_what_a_test_against_a_string_does_not_narrow()
  -- a `mut` field may change under the test
  refused("local record R\n  mut k: string\nend\nlocal function f(r: R): \"a\"?\n  if r.k == \"a\" then\n" ..
      "    return r.k\n  end\n  return nil\nend\nprint(f({ k = \"a\" }))\n", "not_assignable")
  -- what fails the test keeps the members that are no string, and the rest of `string`
  accepted("local function f(v: string | integer): integer\n  if v ~= \"a\" then\n    if v is integer then\n" ..
      "      return v\n    end\n    return #v\n  end\n  local a: \"a\" = v\n  return #a\nend\nprint(f(1))\n")
  accepted("local function f(v: string?): integer\n  if v == \"a\" then\n    return #v\n  end\n  return 0\nend\nprint(f(nil))\n")
end

local function test_two_enums_of_the_same_strings_are_below_each_other_and_their_collections_are_not()
  local both = "local enum A\n  \"a\"\nend\nlocal enum B\n  \"a\"\n  \"b\"\nend\n"
  accepted(both .. "local function f(x: A): B\n  return x\nend\nprint(f(\"a\"))\n")
  refused(both .. "local function f(x: B): A\n  return x\nend\nprint(f(\"a\"))\n", "not_assignable")
  refused(both .. "local function f(xs: mut {A}): mut {B}\n  return xs\nend\nprint(#f({ \"a\" }))\n", "invariant_mut")
end

local function test_any_string_is_a_literal_type_whatever_its_bytes()
  accepted("local e: \"\" = \"\"\nprint(#e)\n")
  typed("local b: \"\\xff\" = \"\\xff\"\n", "b", "\"\\255\"")
  -- a module that requires another reads its literal types as the same
  local r = Programs.run("local M = require(\"m\")\nlocal k: \"on\" = M.k\nprint(k)\n",
    { m = "local record M\n  k: \"on\" | \"off\"\nend\nlocal m: M = { k = \"on\" }\nreturn m\n" })
  assert(Programs.codes(r) == "not_assignable", Programs.codes(r))
  local fine = Programs.run("local M = require(\"m\")\nlocal k: \"on\" | \"off\" = M.k\nprint(k)\n",
    { m = "local record M\n  k: \"on\" | \"off\"\nend\nlocal m: M = { k = \"on\" }\nreturn m\n" })
  assert(Programs.codes(fine) == "", Programs.codes(fine))
end

local function test_a_literal_type_round_trips_through_its_text_into_another_store()
  local Types = require("lang.types")
  local one = Types.new()
  local text = Types.encode(one:union({ Types.literal(one, "a\nb"), Types.literal(one, "") }))
  local other = Types.new()
  local back, why = other:decode(text)
  assert(back ~= nil, why)
  assert(Types.display(back) == "\"\" | \"a\\nb\"", Types.display(back))
end

local function test_a_test_of_a_string_literal_type_runs_as_a_comparison()
  Programs.stands("local function f(v: string | integer): string\n  if v is \"a\\nb\" then\n    return \"yes\"\n  end\n" ..
      "  return \"no\"\nend\nprint(f(\"a\\nb\"))\nprint(f(\"a\"))\nprint(f(1))\n", "yes,no,no")
end
