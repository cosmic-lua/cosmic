--- Tests of the typed coroutines in [`lang.check`] ([`lang/stdlib.d.tl`] declares them): a `Coroutine<Y, R, S>`
--- yields `Y` through the handle its body is given, returns `R` and is sent `S`. Every program the checker takes is also
--- run as the Lua [`lang.codegen`] writes, over the typed library [`lang.check_programs`] describes the declarations
--- with ([`Programs.execute`]).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

--- The codes of checking `source`.
local function codes_of(source: string): string
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  return Programs.codes(r)
end

--- Checks that `source` is taken, runs, and prints `want` (joined by commas).
local function stands(source: string, want: string)
  local x = Programs.execute(source, true)
  assert(#x.run.before == 0, table.concat(x.run.before, " ") .. " in\n" .. source)
  assert(x.ran, Programs.codes(x.run) .. " in\n" .. source)
  assert(x.fault == nil, tostring(x.fault) .. " in\n" .. x.lua)
  assert(table.concat(x.printed, ",") == want, table.concat(x.printed, ",") .. ", wanted " .. want .. " in\n" .. source)
end

--- Checks that `source` is refused with exactly `codes`.
local function refused(source: string, codes: string)
  local got = codes_of(source)
  assert(got == codes, "wanted " .. codes .. ", got " .. got .. " in\n" .. source)
end

--- The type of the last variable called `name` after checking `source`.
local function type_of(source: string, name: string): string
  local r = Programs.run(source)
  assert(#r.before == 0 and Programs.codes(r) == "", table.concat(r.before, " ") .. Programs.codes(r) .. " in\n" .. source)
  local found: Types.Type | nil = nil
  for _, v in ipairs(r.scoped.list) do
    if v.name == name then
      found = r.result.vars[v.id] or found
    end
  end
  assert(found ~= nil, "no variable " .. name)
  return Types.display(found)
end

--- A coroutine that yields its first value's length, then the second value's, and returns whether it was sent two.
local COUNTER <const> = [[
local counter = coroutine.create(function(y: Yielder<integer, string>, first: string): boolean
  local second = y:yield(#first)
  y:yield(#second)
  return true
end)
]]

local function test_a_coroutine_is_typed_by_what_it_yields_returns_and_is_sent()
  assert(type_of(COUNTER, "counter") == "Coroutine<integer, boolean, string>")
  assert(type_of("local gone = coroutine.create(function(y: Yielder<integer, nil>): string\n  return \"a\"\nend)\n", "gone") ==
      "Coroutine<integer, string, nil>")
  assert(type_of("local quiet = coroutine.create(function(y: Yielder<string, nil>)\nend)\n", "quiet") == "Coroutine<string, nil, nil>")
  assert(type_of("local only = coroutine.create(function(): integer\n  return 1\nend)\n", "only") == "Coroutine<never, integer, nil>")
end

local function test_resume_sends_a_value_and_answers_what_was_yielded_or_returned_or_the_error()
  stands(COUNTER .. "local function step(sent: string)\n  match coroutine.resume(counter, sent) do\n    | (true, v) then print(v)\n" ..
      "    | (false, why) then print(\"raised\")\n  end\nend\nstep(\"abc\")\nstep(\"de\")\nstep(\"\")\nprint(coroutine.status(counter))\n",
    "3,2,true,dead")
  stands("local boom = coroutine.create(function(y: Yielder<integer, nil>): integer\n  error(\"no\")\nend)\n" ..
      "match coroutine.resume(boom) do\n  | (true, v) then print(v)\n  | (false, why) then print(\"raised\")\nend\n", "raised")
  -- What the match binds is what the coroutine yields or returns.
  assert(type_of(COUNTER .. "match coroutine.resume(counter, \"x\") do\n  | (true, v) then\n    local seen = v\n  | (false, why) then\n  end\n",
    "seen") == "integer | boolean")
  assert(type_of(COUNTER .. "match coroutine.resume(counter, \"x\") do\n  | (true, v) then\n  | (false, why) then\n    local seen = why\n  end\n",
    "seen") == "any")
  -- A coroutine sent nothing is resumed with no value.
  stands("local gen = coroutine.create(function(y: Yielder<integer, nil>): string\n  y:yield(1)\n  return \"end\"\nend)\n" ..
      "match coroutine.resume(gen) do\n  | (true, v) then print(v)\n  | (false, why) then print(0)\nend\nmatch coroutine.resume(gen) do\n" ..
      "  | (true, v) then print(v)\n  | (false, why) then print(0)\nend\n", "1,end")
end

local function test_the_value_resume_sends_and_the_value_yield_gives_are_held_to_the_types()
  refused(COUNTER .. "local r = coroutine.resume(counter, 1)\n", "overload_none")
  refused(COUNTER .. "local r = coroutine.resume(counter)\n", "overload_none")
  refused("local gen = coroutine.create(function(y: Yielder<integer, nil>)\nend)\nlocal r = coroutine.resume(gen, 1)\n", "overload_none")
  -- The handle yields the type of the coroutine and answers the type it is sent.
  refused("local bad = coroutine.create(function(y: Yielder<integer, string>, first: string)\n  y:yield(\"x\")\nend)\n", "not_assignable")
  refused("local bad = coroutine.create(function(y: Yielder<integer, string>, first: string)\n  local n: integer = y:yield(1)\nend)\n",
    "not_assignable")
  stands("local c = coroutine.create(function(y: Yielder<integer, string>, first: string)\n  local got: string = y:yield(1)\n  print(got)\nend)\n" ..
      "coroutine.resume(c, \"go\")\ncoroutine.resume(c, \"back\")\n", "back")
end

local function test_a_body_takes_the_handle_and_the_first_value_it_is_sent()
  stands("local c = coroutine.create(function(y: Yielder<integer, integer>, first: integer): integer\n  local second = y:yield(first + 1)\n" ..
      "  return second * 2\nend)\ncoroutine.resume(c, 10)\nmatch coroutine.resume(c, 4) do\n  | (true, v) then print(v)\n" ..
      "  | (false, why) then print(0)\nend\n", "8")
  -- A body of the form no overload has is refused.
  refused("local c = coroutine.create(function(y: Yielder<integer, integer>, first: integer, extra: integer)\nend)\n", "overload_none")
  refused("local c = coroutine.create(function(y: integer)\nend)\n", "overload_none")
end

local function test_a_type_expected_gives_the_types_a_body_leaves_out()
  stands("local c: Coroutine<integer, nil, nil> = coroutine.create(function(y, s)\n  y:yield(5)\nend)\nmatch coroutine.resume(c) do\n" ..
      "  | (true, v) then print(v)\n  | (false, why) then print(0)\nend\n", "5")
  -- Nothing says what it yields.
  refused("local c = coroutine.create(function(y, s)\nend)\n", "overload_none")
  refused("local c = coroutine.create(function(y: Yielder<integer, nil>)\n  y:yield(1)\nend)\nlocal d: Coroutine<string, nil, nil> = c\n",
    "not_assignable")
end

local function test_wrap_answers_a_function_that_yields_and_returns_what_the_body_does()
  stands("local gen = coroutine.wrap(function(y: Yielder<integer, nil>)\n  y:yield(1)\n  y:yield(2)\nend)\nprint(gen(), gen(), gen())\n", "1\t2\tnil")
  assert(type_of("local gen = coroutine.wrap(function(y: Yielder<integer, nil>)\n  y:yield(1)\nend)\n", "gen") == "function(): integer?")
  assert(type_of("local gen = coroutine.wrap(function(y: Yielder<integer, string>, s: string): boolean\n  return true\nend)\n", "gen") ==
      "function(string): integer | boolean")
  stands("local total = 0\nfor v in coroutine.wrap(function(y: Yielder<integer, nil>)\n  y:yield(3)\n  y:yield(4)\nend) do\n  total = total + v\nend\n" ..
      "print(total)\n", "7")
end

local function test_close_and_status_are_typed_and_a_closed_coroutine_is_dead()
  stands(COUNTER .. "coroutine.resume(counter, \"abc\")\nprint(coroutine.status(counter))\n" ..
      "match coroutine.close(counter) do\n  | (true) then print(\"closed\")\n  | (false, why) then print(\"failed\")\nend\nprint(coroutine.status(counter))\n",
    "suspended,closed,dead")
  assert(type_of(COUNTER .. "local st = coroutine.status(counter)\n", "st") == "coroutine.Status")
  refused(COUNTER .. "if coroutine.status(counter) == \"sleeping\" then\nend\n", "enum_member")
end

local function test_the_raw_functions_of_the_library_are_not_in_the_typed_one()
  refused("local running = coroutine.running()\n", "field_unknown")
  refused("coroutine.yield(1)\n", "field_unknown")
end

local function test_a_handle_yields_only_for_the_coroutine_it_was_made_for()
  -- The types agree, so the checker takes it; the library holds the handle to its coroutine and the run says so.
  local x = Programs.execute("local record Hold\n  mut handle: Yielder<integer, nil>?\nend\nlocal hold: Hold = { handle = nil }\n" ..
      "local a = coroutine.create(function(y: Yielder<integer, nil>)\n  hold.handle = y\n  y:yield(1)\nend)\n" ..
      "local b = coroutine.create(function(z: Yielder<integer, nil>)\n  local h = hold.handle\n  if h ~= nil then\n    h:yield(2)\n  end\nend)\n" ..
      "coroutine.resume(a)\nmatch coroutine.resume(b) do\n  | (true, v) then print(\"yielded\")\n  | (false, why) then print(\"refused\")\nend\n",
    true)
  assert(x.ran and x.fault == nil, Programs.codes(x.run) .. " " .. tostring(x.fault))
  assert(table.concat(x.printed, ",") == "refused", table.concat(x.printed, ","))
end
