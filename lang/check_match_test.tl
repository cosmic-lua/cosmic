--- Tests of `match` and of the protected calls in [`lang.check`]: the arms cover the lists a call may answer exactly, each
--- name takes the type its lists have, and `pcall` and `xpcall` answer the tagged lists of a call that returned and one
--- that raised. Every program the checker takes is also run as the Lua [`lang.codegen`] writes ([`Programs.execute`]); a
--- program that would fail at run time if a rule had a hole is held refused beside the one that stands.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local HEAD <const> = [[
local type Reply = function(): (true, integer) | (false, string)
local function ok(): (true, integer) | (false, string)
  return true, 7
end
local function bad(): (true, integer) | (false, string)
  return false, "no"
end
local function either(win: boolean): (true, integer) | (false, string)
  if win then
    return true, 1
  end
  return false, "lost"
end
local function triple(): (true, integer, string) | (false, string)
  return true, 1, "x"
end
]]

--- The codes of checking `body` after the head.
local function codes_of(body: string): string
  local r = Programs.run(HEAD .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  return Programs.codes(r)
end

--- Checks that `body` is taken, runs, and prints `want` (joined by commas).
local function stands(body: string, want: string)
  local x = Programs.execute(HEAD .. body, true)
  assert(#x.run.before == 0, table.concat(x.run.before, " ") .. " in\n" .. body)
  assert(x.ran, Programs.codes(x.run) .. " in\n" .. body)
  assert(x.fault == nil, tostring(x.fault) .. " in\n" .. x.lua)
  assert(table.concat(x.printed, ",") == want, table.concat(x.printed, ",") .. ", wanted " .. want .. " in\n" .. body)
end

--- Checks that `body` is refused with exactly `codes`.
local function refused(body: string, codes: string)
  local got = codes_of(body)
  assert(got == codes, "wanted " .. codes .. ", got " .. got .. " in\n" .. body)
end

--- The type of the last variable called `name` after checking `body`.
local function type_of(body: string, name: string): string
  local r = Programs.run(HEAD .. body)
  assert(#r.before == 0 and Programs.codes(r) == "", table.concat(r.before, " ") .. Programs.codes(r) .. " in\n" .. body)
  local found: Types.Type | nil = nil
  for _, v in ipairs(r.scoped.list) do
    if v.name == name then
      found = r.result.vars[v.id] or found
    end
  end
  assert(found ~= nil, "no variable " .. name)
  return Types.display(found)
end

-- match ------------------------------------------------------------------------------------------------------

local function test_each_arm_takes_the_list_its_true_and_false_select_and_names_its_values()
  stands("match ok() do\n  | (true, n) then print(n + 1)\n  | (false, why) then print(why)\nend\n", "8")
  stands("match bad() do\n  | (true, n) then print(n + 1)\n  | (false, why) then print(why)\nend\n", "no")
  assert(type_of("match ok() do\n  | (true, count) then\n    local seen = count\n  | (false, why) then\n  end\n", "seen") == "integer")
  assert(type_of("match ok() do\n  | (true, n) then\n  | (false, reason) then\n    local seen = reason\n  end\n", "seen") == "string")
  -- A list of three values, and an arm that ignores one.
  stands("match triple() do\n  | (true, n, s) then print(n, s)\n  | (false, why) then print(why)\nend\n", "1\tx")
  stands("match triple() do\n  | (true, n, _) then print(n)\n  | (false, _) then print(0)\nend\n", "1")
  -- The call may be a method call.
  stands("local class Tool\n  n: integer\n  function run(self): (true, integer) | (false, string)\n    return true, self.n\n  end\nend\n" ..
      "local t: Tool = { n = 5 }\nmatch t:run() do\n  | (true, n) then print(n)\n  | (false, why) then print(why)\nend\n", "5")
end

local function test_a_name_in_an_arm_is_the_type_of_the_lists_the_arm_takes_and_not_of_the_others()
  assert(type_of("match ok() do\n  | (flag, value) then\n    local seen = value\n  end\n", "seen") == "integer | string")
  assert(type_of("match ok() do\n  | (flag, value) then\n    local seen = flag\n  end\n", "seen") == "boolean")
  -- A name the arm does not use is its own type, and an earlier arm takes its list away from a later one.
  assert(type_of("match ok() do\n  | (true, n) then\n  | (flag, rest) then\n    local seen = rest\n  end\n", "seen") == "string")
  -- A use of a name past its arm is no name of the program.
  local past = Programs.run(HEAD .. "match ok() do\n  | (true, n) then\n  | (false, why) then\nend\nprint(n)\n")
  assert(table.concat(past.before, " ") == "unknown_variable", table.concat(past.before, " "))
end

local function test_a_match_must_take_every_list_the_call_may_answer()
  refused("match ok() do\n  | (true, n) then print(n)\nend\n", "match_missing")
  refused("match ok() do\n  | (false, why) then print(why)\nend\n", "match_missing")
  local r = Programs.run(HEAD .. "match ok() do\n  | (true, n) then print(n)\nend\n")
  local e = r.errors[#r.errors]
  assert(e.code == "match_missing" and e.msg:find("takes no arm for the list `(false, string)`", 1, true) ~= nil, e.msg)
  assert(e.fix:find("add the arm `| (false, v2) then ...`", 1, true) ~= nil, e.fix)
  -- An arm with no test takes what is left.
  stands("match ok() do\n  | (true, n) then print(n)\n  | (other, rest) then print(rest)\nend\n", "7")
  refused("match triple() do\n  | (true, n, s) then print(n)\nend\n", "match_missing")
end

local function test_an_arm_that_takes_no_list_or_only_lists_taken_before_it_is_refused()
  refused("match ok() do\n  | (true, n) then print(n)\n  | (true, m) then print(m)\n  | (false, why) then print(why)\nend\n", "match_redundant")
  refused("match ok() do\n  | (true, n) then print(n)\n  | (false, why) then print(why)\n  | (other, rest) then print(rest)\nend\n", "match_redundant")
  -- A call that answers one list is taken by one arm.
  stands("local function one(): (string, integer)\n  return \"a\", 1\nend\nmatch one() do\n  | (s, n) then print(s, n)\nend\n", "a\t1")
end

local function test_an_arm_names_each_value_of_the_lists_it_takes()
  refused("match ok() do\n  | (true) then print(1)\n  | (false, why) then print(why)\nend\n", "match_pattern")
  refused("match ok() do\n  | (true, n, extra) then print(n)\n  | (false, why) then print(why)\nend\n", "match_pattern")
  refused("match triple() do\n  | (true, n) then print(n)\n  | (false, why) then print(why)\nend\n", "match_pattern")
  -- A position that is `boolean` or an integer is not one `true` and `false` tell.
  refused("local function f(): (boolean, integer)\n  return true, 1\nend\nmatch f() do\n  | (true, n) then print(n)\nend\n", "match_pattern")
  refused("local function f(): (integer, boolean)\n  return 1, true\nend\nmatch f() do\n  | (true, n) then print(n)\nend\n", "match_pattern")
  -- A test of a position past the values of a list.
  refused("match ok() do\n  | (true, n, true) then print(n)\n  | (false, why) then print(why)\nend\n", "match_pattern")
end

local function test_a_name_past_the_values_of_a_list_with_a_tail_may_be_nil()
  local head = "local function many(): integer...\n  return 1\nend\n"
  local shown = type_of(head .. "match many() do\n  | (a, b) then local seen = b\nend\n", "seen")
  assert(shown == "integer?", shown)
end

local function test_the_tag_may_be_any_position_of_the_lists_and_a_name_before_it_takes_every_list()
  local head = "local function f(win: boolean): (string, true, integer) | (string, false)\n  if win then\n    return \"a\", true, 2\n  end\n  return \"b\", false\nend\n"
  stands(head .. "match f(true) do\n  | (s, true, n) then print(s, n)\n  | (s, false) then print(s)\nend\n", "a\t2")
  assert(codes_of(head .. "match f(true) do\n  | (s, true, n) then print(s, n)\nend\n") == "match_missing")
end

local function test_what_follows_a_match_is_where_the_ends_of_the_arms_meet()
  -- An arm that returns leaves the others, and the narrowing they share.
  stands("local function get(win: boolean): integer\n  local found = nil\n  match either(win) do\n    | (true, n) then return n\n" ..
      "    | (false, why) then return #why\n  end\nend\nprint(get(true), get(false))\n", "1\t4")
  refused("local function get(win: boolean): integer\n  match either(win) do\n    | (true, n) then return n\n    | (false, why) then print(why)\n" ..
      "  end\nend\n", "missing_return")
  stands("local function get(win: boolean): integer\n  local result: integer? = nil\n  match either(win) do\n    | (true, n) then result = n\n" ..
      "    | (false, why) then result = #why\n  end\n  return result\nend\nprint(get(true), get(false))\n", "1\t4")
  refused("local function get(win: boolean): integer\n  local result: integer? = nil\n  match either(win) do\n    | (true, n) then result = n\n" ..
      "    | (false, why) then print(why)\n  end\n  return result\nend\n", "nil_not_allowed")
end

local function test_a_binding_of_an_arm_is_the_arms_own()
  stands("local m = 10\nmatch ok() do\n  | (true, n) then print(n)\n  | (false, why) then print(why)\nend\nprint(m)\n", "7,10")
  refused("match ok() do\n  | (true, n) then local s: string = n\n  | (false, why) then local m: integer = why\nend\n",
    "not_assignable not_assignable")
end

-- pcall and xpcall ------------------------------------------------------------------------------------------------

local function test_pcall_answers_the_values_of_the_call_or_the_error()
  stands("local function f(n: integer): integer\n  return n + 1\nend\nmatch pcall(f, 1) do\n  | (true, n) then print(n)\n  | (false, why) then print(\"raised\")\nend\n", "2")
  stands("local function f(n: integer): integer\n  error(\"boom\")\nend\nmatch pcall(f, 1) do\n  | (true, n) then print(n)\n  | (false, why) then print(\"raised\")\nend\n",
    "raised")
  assert(type_of("local function f(): string\n  return \"a\"\nend\nlocal okay, v = pcall(f)\n", "okay") == "boolean")
  assert(type_of("local function f(): string\n  return \"a\"\nend\nmatch pcall(f) do\n  | (true, v) then\n    local seen = v\n  | (false, why) then\n  end\n",
    "seen") == "string")
  -- A function that answers nothing, and one that answers two values.
  stands("local function g() end\nmatch pcall(g) do\n  | (true) then print(\"done\")\n  | (false, why) then print(\"raised\")\nend\n", "done")
  stands("local function h(): integer, string\n  return 1, \"x\"\nend\nmatch pcall(h) do\n  | (true, n, s) then print(n, s)\n  | (false, why) then print(\"raised\")\nend\n",
    "1\tx")
  -- A function literal says what it answers.
  stands("match pcall(function(): integer return 3 end) do\n  | (true, n) then print(n)\n  | (false, why) then print(0)\nend\n", "3")
end

local function test_the_arguments_of_pcall_are_held_to_the_parameters_of_the_function()
  refused("local function f(n: integer): integer\n  return n\nend\nlocal okay, v = pcall(f, \"x\")\n", "overload_none")
  refused("local function f(n: integer): integer\n  return n\nend\nlocal okay, v = pcall(f)\n", "overload_none")
  refused("local function f(n: integer): integer\n  return n\nend\nlocal okay, v = pcall(f, 1, 2)\n", "overload_none")
  refused("local okay, v = pcall(7)\n", "overload_none")
  stands("local function f(a: string, b: integer): string\n  return a .. tostring(b)\nend\nlocal okay, v = pcall(f, \"n\", 2)\nprint(okay, v)\n", "true\tn2")
end

local function test_a_refused_protected_call_names_the_limits_of_the_overloads()
  local r = Programs.run(HEAD .. "local function many(): (integer, integer, integer, integer)\n  return 1, 2, 3, 4\nend\n" ..
      "local okay, v = pcall(many)\n")
  assert(#r.errors == 1 and r.errors[1].code == "overload_none", Programs.codes(r))
  assert(r.errors[1].fix:find("`pcall` passes on at most 6 values", 1, true) ~= nil, r.errors[1].fix)
  assert(r.errors[1].fix:find("answers at most 3 values and none that answers `T...`", 1, true) ~= nil, r.errors[1].fix)
end

local function test_a_protected_call_is_no_value_to_one_name_and_its_failure_is_untrusted_data()
  refused("local function f(): integer\n  return 1\nend\nlocal okay = pcall(f)\n", "alternatives_as_value")
  refused("local function f(): integer\n  return 1\nend\nlocal okay, why = pcall(f)\nlocal n: string = why\n", "any_use")
  refused("local function f(): integer\n  return 1\nend\nmatch pcall(f) do\n  | (true, n) then print(n)\n  | (false, why) then print(why .. \"\")\nend\n", "any_use")
  stands("local function f(): integer\n  return 1\nend\nmatch pcall(f) do\n  | (true, n) then print(n)\n  | (false, why) then print(tostring(why))\nend\n", "1")
end

local function test_xpcall_answers_what_the_message_handler_answers_on_failure()
  local head = "local function f(n: integer): integer\n  error(\"boom\")\nend\nlocal function handler(e: any): string\n  return \"handled\"\nend\n"
  stands(head .. "match xpcall(f, handler, 1) do\n  | (true, n) then print(n)\n  | (false, why) then print(why)\nend\n", "handled")
  assert(type_of(head .. "match xpcall(f, handler, 1) do\n  | (true, n) then\n  | (false, why) then\n    local seen = why\n  end\n", "seen") == "string")
  refused(head .. "local okay, v = xpcall(f, handler, \"x\")\n", "overload_none")
  -- A handler that raises is answered by Lua's own string, so the failure is not the handler's number.
  local raising = "local function risky(): integer\n  error(\"a\")\nend\nlocal function code(m: any): integer\n  error(\"handler dies\")\nend\n"
  local shown = type_of(raising .. "match xpcall(risky, code) do\n  | (true, v) then\n  | (false, n) then\n    local seen = n\n  end\n", "seen")
  assert(shown == "integer | string", shown)
  refused(raising .. "match xpcall(risky, code) do\n  | (true, v) then print(v)\n  | (false, n) then print(n + 1)\nend\n", "operand_type")
  stands(raising .. "match xpcall(risky, code) do\n  | (true, v) then print(v)\n  | (false, n) then print(n)\nend\n", "error in error handling")
end
