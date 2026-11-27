--- Tests of the calls that return a value or a failure, `(T) | (nil, E)`, in [`lang.check`]: the lists are told apart
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

--- `e!` is `must(e)`: the value of a `(T) | (nil, E)` call, or a raise with its reason; on a value that may be nil,
--- the value. It reads on as a call does, and the failure list is no value without it.
--- `!` raises at nil alone, as `assert` does not: a `false` passes. So the value of a `(boolean) | (nil, E)` call, a
--- `boolean?` and a map read of booleans are taken with `!`, and `v!` narrows `v` as `v ~= nil` does.
local function test_a_must_passes_false()
  stands("print(flag(true)!)\n", "false")
  stands("local ok, why = pcall(function(): boolean\n  local v = flag(false)!\n  return v\nend)\nprint(ok, why)\n", "false\tt:15: off")
  assert(type_of("local seen = flag(true)!\n", "seen") == "boolean")
  stands("local t: {string: boolean} = { a = false }\nprint(t[\"a\"]!)\n", "false")
  stands("local function f(v: boolean?): boolean\n  v!\n  return v\nend\nprint(f(false))\n", "false")
  stands("local function take(v: boolean?): boolean\n  return v!\nend\nlocal ok, why = pcall(take, nil)\n" ..
      "print(ok, tostring(why):find(\"the value before `!` is nil\", 1, true) ~= nil)\n", "false\ttrue")
  -- A failure told by `false` is no failure to `!`, which would pass it: the lists are refused as `!` cannot tell them apart.
  Programs.says("local function put(on: boolean): (true) | (false, string)\n  if on then\n    return true\n  end\n" ..
      "  return false, \"off\"\nend\nlocal done = put(true)!\nprint(done)\n", "alternatives_as_value", "`put(true)!` tells none of them apart",
    "`local ok, why = put(true)`")
end

local function test_a_must_takes_the_value_or_raises()
  stands("local n: integer = parse(\"4\")!\nprint(n + 1)\n", "5")
  stands("print(parse(\"4\")! * 2, parse(\"7\")! + 1)\n", "8\t8")
  stands("local t: {string: integer} = { a = 1 }\nprint(t[\"a\"]! + 1)\n", "2")
  stands("local ok, why = pcall(function(): integer return parse(\"x\")! end)\n" ..
      "print(ok, tostring(why):find(\"not a number: x\", 1, true) ~= nil)\n", "false\ttrue")
  assert(type_of("local seen = parse(\"4\")!\n", "seen") == "integer")
  refused("print(parse(\"4\") + 1)\n", "alternatives_as_value")
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

local function test_a_call_that_may_fail_is_no_statement()
  refused("parse(\"x\")\n", "failure_ignored")
  refused("local function f(): (true, integer) | (false, string)\n  return true, 1\nend\nf()\n", "failure_ignored")
  -- Discarding both values says so on purpose, and binding them is how the failure is read.
  stands("local _, _ = parse(\"x\")\nprint(\"on\")\n", "on")
  stands("local _, _ = pcall(error, \"x\")\nprint(\"on\")\n", "on")
  -- A call of one list is a statement as before.
  stands("local function g(): integer\n  print(\"g\")\n  return 1\nend\ng()\n", "g")
end

local function test_the_fix_names_a_binding_the_checker_takes()
  -- A method call, a protected call and a resumed coroutine are held alike.
  Programs.says("local class Tool\n  function run(self): (integer) | (nil, string)\n    return 1\n  end\nend\n" ..
      "local t: Tool = {}\nt:run()\n", "failure_ignored", "`t:run()` answers one of 2 lists", "`local v, why = t:run()`")
  Programs.says("local function f(): integer\n  return 1\nend\npcall(f)\n", "failure_ignored", nil, "`local _, _ = pcall(f)`")
  Programs.says("local c = coroutine.create(function(): integer\n  return 1\nend)\ncoroutine.resume(c)\n", "failure_ignored")
  -- Three values are named one by one, and a call too long to show whole is spelled by its callee.
  Programs.says("local function f(): (true, integer, string) | (false, string)\n  return true, 1, \"x\"\nend\nf()\n",
    "failure_ignored", nil, "`local ok, why, v3 = f()`")
  Programs.says("local function f(a: integer, b: integer, c: integer, d: integer): (integer) | (nil, string)\n  return a\n" ..
      "end\nf(1111111111111, 2222222222222, 3333333333333, 4444444444444)\n", "failure_ignored", nil, "`local _, _ = f(...)`")
  -- What the fix names stands.
  stands("local ok, why, v3 = pcall(function(): (integer, string)\n  return 1, \"x\"\nend)\nprint(ok, v3)\n", "true\tx")
end

local function test_a_failure_with_a_text_of_its_own_is_read_by_tostring()
  -- A class with a `__tostring`, as a [`cosmic.failure`] is, is no string: where one is wanted, the fix reads its text.
  local class = "local class F\n  message: string\n  function __tostring(self): string\n    return self.message\n" ..
    "  end\nend\nlocal why: F = { message = \"gone\" }\n"
  Programs.says(class .. "local s: string = why\nprint(s)\n", "not_assignable", nil, "`tostring(why)`")
  Programs.says(class .. "local function take(s: string?)\n  print(s)\nend\ntake(why)\n", "not_assignable", nil,
    "`tostring(why)`")
  Programs.says(class .. "print(\"x: \" .. why)\n", "operand_type", nil, "`tostring(why)`")
  Programs.stands(class .. "local s: string = tostring(why)\nprint(\"x: \" .. s)\n", "x: gone")
end

local function test_assert_passes_the_list_that_is_no_failure()
  -- `assert` raises at a nil or false first value, so what it returns is the one list whose first value is neither.
  assert(type_of("local n = assert(parse(\"4\"))\n", "n") == "integer")
  stands("print(assert(parse(\"4\")) + 1)\n", "5")
  local pair = "local function pair(on: boolean): (true, integer) | (false, string)\n  if on then\n    return true, 3\n" ..
    "  end\n  return false, \"off\"\nend\n"
  Programs.stands(pair .. "local ok, v = assert(pair(true))\nprint(ok, v + 1)\n", "true\t4")
  -- The failure is what it raises.
  stands("local ok, raised = pcall(function()\n  local _ = assert(parse(\"x\"))\nend)\nprint(ok, raised)\n",
    "false\tt:15: not a number: x")
  -- Where the value of the list that is no failure may be false, `assert` would raise at it too: no list passes.
  Programs.says(HEAD .. "local f = assert(flag(true))\nprint(f)\n", "alternatives_as_value", "`assert` tells none of them apart",
    "`local v, why = flag(true)`")
  -- A list whose first value may be true or false (a `boolean`) may pass `assert` as well: none is chosen.
  Programs.says("local function f(on: boolean): (integer, true) | (boolean, false)\n  if on then\n    return 1, true\n" ..
      "  end\n  return true, false\nend\nlocal a = assert(f(false))\nprint(a)\n", "alternatives_as_value",
    "`assert` tells none of them apart")
  -- In `assert(x, f())`, `x` is what `assert` tests: the call is no value there.
  refused("print(assert(true, parse(\"x\")))\n", "alternatives_as_value")
  -- Elsewhere a call that may fail is still no value.
  refused("print(parse(\"4\"))\n", "alternatives_as_value")
end
