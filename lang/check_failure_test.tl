--- Tests of the calls that answer a value or a failure, `(T) | (nil, E)`, in [`lang.check`]: the lists are told apart
--- by a first value that is `nil` or never nil, a test of the first local narrows the others, and `match` takes the lists
--- apart with a `nil` pattern. Every program the checker takes is also run.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

local HEAD <const> = [[
local function parse(s: string): (integer) | (nil, string)
  local n = math.tointeger(tonumber(s))
  if n == nil then
    return nil, "not a number: " .. s
  end
  return n
end
local function flag(on: boolean): (boolean) | (nil, string)
  if on then
    return false
  end
  return nil, "off"
end
]]

local function stands(body: string, want: string)
  Programs.stands(HEAD .. body, want)
end

local function refused(body: string, codes: string)
  Programs.refused(HEAD .. body, codes)
end

local function type_of(body: string, name: string): string
  return Programs.type_of(HEAD .. body, name)
end

local function test_lists_told_apart_by_a_first_nil_are_declared()
  stands("local n, why = parse(\"4\")\nprint(n, why)\n", "4\tnil")
  -- A value at that position that may be nil tells nothing, nor one that stands for any type: [`lang.declarations_test`].
  -- Any position may tell the lists apart.
  Programs.stands("local function f(): (string, integer) | (string, nil, string)\n  return \"a\", nil, \"b\"\nend\n" ..
    "match f() do\n  | (_, nil, e) then print(e)\n  | (s, n) then print(s, n)\nend\n", "b")
end

local function test_a_test_of_the_first_local_narrows_the_failure()
  refused("local n, why = parse(\"x\")\nprint(#why)\n", "nil_not_allowed")
  refused("local n, why = parse(\"4\")\nprint(n + 1)\n", "nil_not_allowed")
  stands("local n, why = parse(\"x\")\nif n == nil then\n  print(#why)\nelse\n  print(n + 1)\nend\n", "15")
  stands("local n, why = parse(\"4\")\nif n ~= nil then\n  print(n + 1)\nelse\n  print(#why)\nend\n", "5")
  stands("local n, why = parse(\"x\")\nif not n then\n  print(why)\nend\n", "not a number: x")
  stands("local n, why = parse(\"4\")\nif n then\n  print(n + 1)\nelse\n  print(why:upper())\nend\n", "5")
  stands("local function f(s: string): integer\n  local n, why = parse(s)\n  if n == nil then\n    error(why)\n  end\n  return n * 2\nend\nprint(f(\"3\"))\n", "6")
  assert(type_of("local n, why = parse(\"x\")\nif n == nil then\n  local seen = why\nend\n", "seen") == "string")
  assert(type_of("local n, why = parse(\"4\")\nif n ~= nil then\n  local seen = why\nend\n", "seen") == "nil")
  -- The wrong list is refused.
  refused("local n, why = parse(\"4\")\nif n ~= nil then\n  print(#why)\nend\n", "nil_not_allowed")
end

local function test_each_form_of_the_test_narrows()
  stands("local n, why = parse(\"x\")\nif nil == n then\n  print(#why)\nend\n", "15")
  stands("local n, why = parse(\"4\")\nassert(n ~= nil)\nprint(n + 1)\n", "5")
  stands("local n, why = parse(\"4\")\nassert(n)\nprint(n + 1)\n", "5")
  stands("local n, why = parse(\"4\")\nprint(n and n + 1)\n", "5")
  stands("local n, why = parse(\"x\")\nwhile n == nil do\n  print(#why)\n  break\nend\n", "15")
end

local function test_a_member_that_may_be_nil_or_false_in_a_union_tells_nothing()
  -- An alias inside a union is read through: `A | string` may be nil, and `Flag | string` false.
  local r = Programs.run("local type A = integer?\nlocal function f(): (A | string) | (nil, string)\n  return nil\nend\n")
  assert(table.concat(r.before, " ") == "lists_overlap", table.concat(r.before, " "))
  refused("local type Flag = boolean\nlocal function g(on: boolean): (Flag | string) | (nil, string)\n  if on then\n" ..
    "    return false\n  end\n  return nil, \"x\"\nend\nlocal v, why = g(true)\nif not v then\n  print(#why)\nend\n",
    "condition_type nil_not_allowed")
end

local function test_three_lists_are_tied_by_the_one_that_is_nil()
  local head = "local function f(k: integer): (true, integer) | (false, string) | (nil, string)\n" ..
    "  if k == 1 then\n    return true, 1\n  elseif k == 2 then\n    return false, \"c\"\n  end\n  return nil, \"no\"\nend\n"
  Programs.stands(head .. "local v, why = f(3)\nif v == nil then\n  print(#why)\nelse\n  print(v, why)\nend\n", "2")
  assert(Programs.type_of(head .. "local v, why = f(1)\nif v ~= nil then\n  local seen = why\nend\n", "seen") == "integer | string")
  -- `false` is a value of the second list, so a test of truth tells nothing.
  Programs.refused(head .. "local v, why = f(3)\nif v then\n  print(why)\nelse\n  print(#why)\nend\n", "condition_type operand_type")
end

local function test_a_function_that_assigns_a_local_leaves_it_untied()
  refused("local n, why = parse(\"x\")\nlocal function poke()\n  why = nil\nend\npoke()\nif n == nil then\n  print(#why)\nend\n",
    "nil_not_allowed")
end

local function test_a_first_value_that_may_be_false_is_told_by_nil_and_not_by_truth()
  -- `if v` would take `false` for the failure, so it tells nothing; `v == nil` does.
  refused("local v, why = flag(false)\nif not v then\n  print(#why)\nend\n", "condition_type nil_not_allowed")
  stands("local v, why = flag(false)\nif v == nil then\n  print(#why)\nelse\n  print(v)\nend\n", "3")
  stands("local v, why = flag(true)\nif v ~= nil then\n  print(v)\nend\n", "false")
end

local function test_an_assignment_to_a_local_ends_the_tie()
  refused("local n, why = parse(\"x\")\nwhy = nil\nif n == nil then\n  print(#why)\nend\n", "nil_not_allowed")
  refused("local n, why = parse(\"x\")\nn = nil\nif n == nil then\n  print(#why)\nend\n", "nil_not_allowed")
end

local function test_match_takes_the_lists_apart_with_a_nil_pattern()
  stands("match parse(\"x\") do\n  | (nil, why) then print(why)\n  | (n) then print(n + 1)\nend\n", "not a number: x")
  stands("match parse(\"4\") do\n  | (nil, why) then print(why)\n  | (n) then print(n + 1)\nend\n", "5")
  assert(type_of("match parse(\"4\") do\n  | (nil, why) then\n  | (n) then\n    local seen = n\nend\n", "seen") == "integer")
  -- The arm that takes the value must come after the `nil` one, which a name alone would take as well.
  refused("match parse(\"4\") do\n  | (nil, why) then print(why)\nend\n", "match_missing")
  -- A `nil` pattern does not tell a value that may be nil.
  Programs.refused("local function f(): (integer?, string)\n  return nil, \"x\"\nend\nmatch f() do\n  | (nil, s) then print(s)\n" ..
    "  | (n, s) then print(n, s)\nend\n", "match_pattern match_redundant")
  -- An arm still names each value of a list no arm before it took.
  refused("match parse(\"4\") do\n  | (nil) then print(0)\n  | (n) then print(n)\nend\n", "match_pattern")
  -- `true` and `false` tell a `nil` from them, and so does a test of the first local against `nil`.
  Programs.stands("local function f(on: boolean): (true, integer) | (nil, string)\n  if on then\n    return true, 1\n  end\n" ..
    "  return nil, \"no\"\nend\nlocal ok, v = f(true)\nif ok ~= nil then\n  print(v + 1)\nelse\n  print(#v)\nend\n", "2")
  Programs.stands("local function f(on: boolean): (true, integer) | (nil, string)\n  if on then\n    return true, 1\n  end\n" ..
    "  return nil, \"no\"\nend\nmatch f(false) do\n  | (true, n) then print(n)\n  | (nil, why) then print(why)\nend\n", "no")
end
