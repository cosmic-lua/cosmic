--- String literal types: `"circle"` written as a type is the type of that one string, an enum of it alone. An enum is the
--- set of its strings, below an enum or a union of literals that holds each of them, and a test of a place against a
--- string narrows it to the literal where it holds and to the other strings where it fails.
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
