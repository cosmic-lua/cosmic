--- Tests of the flow of [`lang.check`] ([`lang.flow`]): what a test narrows and what it does not, the joins of `if` and the
--- loops, a closure's view of the locals around it, definite assignment and reachability. Every program the checker takes
--- is also run as the Lua [`lang.codegen`] writes, with each narrowed read checked ([`Programs.execute`]), so a fact that
--- is wrong fails here as the nil or the wrong value it would be at run time. A program that would fail at run time if
--- a rule had a hole is held refused beside the one that stands.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- Every program starts with a source of nil: `find()` answers `"ab"` on its odd calls and nil on its even ones.
local PRELUDE <const> = [[
local record State
  mut n: integer
end
local st: State = { n = 0 }
local function find(): string?
  st.n = st.n + 1
  if st.n % 2 == 0 then
    return nil
  end
  return "ab"
end
]]

--- The codes of checking `body` after the prelude.
local function codes_of(body: string): string
  local r = Programs.run(PRELUDE .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  return Programs.codes(r)
end

--- Checks that `body` is taken, and runs with every narrowed read checked, and prints `want` (joined by commas).
local function stands(body: string, want: string)
  local x = Programs.execute(PRELUDE .. body, true)
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

-- what a test narrows ----------------------------------------------------------------------------------------

local function test_a_test_of_an_optional_narrows_it_in_the_branch_it_holds_and_after_a_branch_that_ends()
  stands("local s = find()\nif s ~= nil then\n  print(#s)\nend\nlocal t = find()\nif t == nil then\n  print(\"none\")\nelse\n" ..
      "  print(#t)\nend\n", "2,none")
  stands("local function len(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  return #s\nend\n" ..
      "print(len(), len())\n", "2\t0")
  stands("local s = find()\nif s then\n  print(#s)\nend\nlocal t = find()\nif not t then\n  print(\"none\")\nend\n", "2,none")
  stands("local function len(): integer\n  local s = find()\n  if not s then\n    return 0\n  end\n  return #s\nend\n" ..
      "print(len(), len())\n", "2\t0")
  -- Where the test of an optional fails the value is nil, and a test of it that holds is the one no value can pass.
  assert(codes_of("local s = find()\nif s then\n  return\nend\nlocal z: nil = s\n") == "")
  refused("local s = find()\nprint(#s)\n", "nil_not_allowed")
  refused("local s = find()\nif s ~= nil then\nend\nprint(#s)\n", "nil_not_allowed")
  refused("local s = find()\nif s == nil then\n  print(1)\nend\nprint(#s)\n", "nil_not_allowed")
end

--- The nil that ends a generic `for` is the end, not a value of the loop variable: an iterator declared `T?` gives a
--- variable that is not optional.
local function test_the_nil_that_ends_a_for_iterator_is_the_end_not_a_value_of_the_variable()
  stands([[
local function words(): function(): string?
  return function(): string?
    st.n = st.n + 1
    if st.n > 3 then
      return nil
    end
    return "ab"
  end
end
for word in words() do
  local n: integer = #word
  print(n)
end
]], "2,2,2")
end

local function test_and_or_and_not_combine_what_their_operands_say()
  stands("local s = find()\nprint(s ~= nil and #s > 1)\nlocal t = find()\nprint(t ~= nil and #t > 1)\n", "true,false")
  stands("local function f(): integer\n  local s = find()\n  if s == nil or #s == 0 then\n    return 0\n  end\n  return #s\nend\n" ..
      "print(f(), f())\n", "2\t0")
  stands("local function f(): integer\n  local s = find()\n  local t = find()\n  if s == nil and t == nil then\n    return 0\n  end\n" ..
      "  if s ~= nil then\n    return #s\n  end\n  return 7\nend\nprint(f())\n", "2")
  stands("local function f(): integer\n  local s = find()\n  local t = find()\n  if not (s ~= nil and t ~= nil) then\n    return 0\n  end\n" ..
      "  return #s + #t\nend\nprint(f())\n", "0")
  -- What follows an `if` knows what every way through it knows, the one that took no branch included.
  refused("local s = find()\nif st.n < 0 then\n  if s == nil then\n    return\n  end\nend\nprint(#s)\n", "nil_not_allowed")
  refused("local s = find()\nif st.n < 0 then\n  if s == nil then\n    return\n  end\nelseif st.n < 0 then\n  print(1)\nend\nprint(#s)\n", "nil_not_allowed")
  -- `or` tells nothing when it holds, `and` nothing when it does not.
  refused("local s = find()\nlocal t = find()\nif s ~= nil or t ~= nil then\n  print(#s)\nend\n", "nil_not_allowed")
  refused("local s = find()\nlocal t = find()\nif s ~= nil and t ~= nil then\nelse\n  print(#s)\nend\n", "nil_not_allowed")
  refused("local s = find()\nlocal t = find()\nif s == nil or t == nil then\n  print(#s)\nend\n", "nil_not_allowed")
  -- What follows an `and` holds what both ways out of it hold: the short cut, where the left failed, knows nothing.
  refused("local s = find()\nlocal ok = s ~= nil and #s > 1\nprint(#s)\n", "nil_not_allowed")
  refused("local s = find()\nlocal ok = s == nil or #s > 1\nprint(#s)\n", "nil_not_allowed")
  -- The right operand of `and` and `or` is read under the left.
  refused("local s = find()\nprint(s == nil and #s)\n", "nil_not_allowed")
  stands("local s = find()\nlocal n: integer = if s ~= nil then #s else 0 end\nprint(n)\n", "2")
end

local function test_is_and_type_and_a_tag_narrow_a_union()
  local head = "local class A\n  n: integer\nend\nlocal class B\n  s: string\nend\n"
  assert(codes_of(head .. "local function f(v: A | B): integer\n  if v is A then\n    return v.n\n  end\n  return #v.s\nend\n") == "")
  refused(head .. "local function f(v: A | B): integer\n  if v is A then\n    return v.n\n  end\n  return v.n\nend\n", "field_unknown")
  stands("local function f(v: string | integer): integer\n  if type(v) == \"string\" then\n    return #v\n  end\n  return v + 1\nend\n" ..
      "print(f(\"abc\"), f(4))\n", "3\t5")
  stands("local function f(v: any): number\n  if type(v) == \"number\" then\n    return v + 1\n  end\n  return 0\nend\n" ..
      "print(f(4), f(\"x\"))\n", "5\t0")
  local tags = "local enum AK \"a\" end\nlocal enum BK \"b\" end\nlocal record A\n  kind: AK\n  n: integer\nend\n" ..
    "local record B\n  kind: BK\n  s: string\nend\n"
  stands(tags .. "local function f(v: A | B): integer\n  if v.kind == \"a\" then\n    return v.n\n  end\n  return #v.s\nend\n" ..
      "print(f({ kind = \"a\", n = 3 }), f({ kind = \"b\", s = \"xy\" }))\n", "3\t2")
  refused(tags .. "local function f(v: A | B): integer\n  return v.n\nend\n", "field_unknown")
  -- A chain of tag tests that covers every member ends the function; one that leaves a member does not.
  assert(codes_of(tags .. "local function f(v: A | B): integer\n  if v.kind == \"a\" then\n    return v.n\n  elseif v.kind == \"b\" then\n" ..
      "    return #v.s\n  end\nend\n") == "")
  assert(codes_of(tags .. "local function f(v: A | B): integer\n  if v.kind == \"a\" then\n    return v.n\n  end\nend\n") == "missing_return")
  assert(codes_of(head .. "local function f(v: A | B): integer\n  if v is A then\n    return v.n\n  elseif v is B then\n    return #v.s\n  end\nend\n") == "")
end

local function test_assert_and_a_narrowing_declaration_narrow_what_follows_the_call()
  -- `assert` is a generic call, typed from its declaration; the narrowing is of the global.
  stands("local s = find()\nassert(s ~= nil)\nprint(#s)\n", "2")
  stands("local s = find()\nassert(s)\nprint(#s)\n", "2")
  stands("local s = find()\nassert(s ~= nil, \"no\")\nprint(#s)\n", "2")
  -- Only the global `assert` is one: a function of the program that is called so narrows nothing.
  assert(codes_of("local function check(v: boolean) end\nlocal s = find()\ncheck(s ~= nil)\nprint(#s)\n") == "nil_not_allowed")
  local is_text = "local function is_text(v: any): v is string\n  return type(v) == \"string\"\nend\n"
  stands(is_text .. "local function f(v: any): integer\n  if is_text(v) then\n    return #v\n  end\n  return 0\nend\nprint(f(\"abc\"), f(1))\n", "3\t0")
  local assertion = "local function check(v: any): asserts v is string\n  if type(v) ~= \"string\" then\n    error(\"not a string\")\n  end\nend\n"
  stands(assertion .. "local function f(v: any): integer\n  check(v)\n  return #v\nend\nprint(f(\"abc\"))\n", "3")
  -- A body that does not prove what the declaration says is refused where it returns.
  refused("local function wrong(v: any): v is string\n  return true\nend\n", "narrows_unproved")
  refused("local function wrong(v: any): v is string\n  return type(v) == \"number\"\nend\n", "narrows_unproved")
  refused("local function wrong(v: any): asserts v is string\nend\n", "narrows_unproved")
  refused("local function wrong(v: any): asserts v is string\n  if type(v) == \"number\" then\n    error(\"no\")\n  end\nend\n", "narrows_unproved")
  assert(codes_of("local function right(v: any): v is string\n  if type(v) == \"string\" then\n    return true\n  end\n  return false\nend\n") == "")
end

-- what drops a fact --------------------------------------------------------------------------------------------

local function test_an_assignment_drops_the_fact_and_names_itself()
  local body = "local s = find()\nif s == nil then\n  return\nend\ns = find()\nprint(#s)\n"
  local r = Programs.run(PRELUDE .. "local function f()\n" .. body .. "end\n")
  assert(Programs.codes(r) == "narrowing_dropped", Programs.codes(r))
  local e = r.errors[1]
  assert(e.msg:find("the assignment at 17:1 dropped that", 1, true) or e.msg:find("dropped that", 1, true), e.msg)
  assert(e.other ~= nil and e.fix:find("test `s` again after the assignment at", 1, true), e.fix)
  -- The value assigned narrows it to the view of its type, and a value that may be nil narrows it to nothing.
  stands("local s = find()\nif s == nil then\n  s = \"x\"\nend\nprint(#s)\n", "2")
  refused("local s = find()\nif s == nil then\n  s = find()\nend\nprint(#s)\n", "nil_not_allowed")
  -- An assignment to a place drops the fields of it that a test narrowed.
  local node = "local record Node\n  next: Node?\n  n: integer\nend\n"
  assert(codes_of(node .. "local function f(a: Node, b: Node): integer\n  if a.next ~= nil then\n    return a.next.n\n  end\n  return 0\nend\n") == "")
  assert(codes_of(node .. "local function f(a: Node, b: Node): integer\n  if a.next ~= nil then\n    a = b\n    return a.next.n\n  end\n  return 0\nend\n") ==
      "narrowing_dropped")
  -- A field declared `mut` is not a place: code that runs between a test and a read can change it.
  assert(codes_of("local record Cell\n  mut next: Cell?\n  n: integer\nend\nlocal function f(c: Cell): integer\n  if c.next ~= nil then\n    return c.next.n\n  end\n  return 0\nend\n") ==
      "nil_not_allowed")
  assert(codes_of("local record Cell\n  mut next: Cell?\n  n: integer\nend\nlocal function f(c: Cell): integer\n  local k = c.next\n  if k ~= nil then\n    return k.n\n  end\n  return 0\nend\n") == "")
end

local function test_a_local_declared_again_is_another_place()
  -- The second `s` is nil on the second call; a fact of the first does not reach it.
  refused("local function f(): integer\n  local _s = find()\n  if _s == nil then\n    return 0\n  end\n  local _s = find()\n  return #_s\nend\n", "nil_not_allowed")
  stands("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local s = s\n  return #s\nend\nprint(f())\n", "2")
  -- `local x = x` keeps the fact of the value it copies, in a loop and past a function declaration.
  stands("local function f(): integer\n  local s = find()\n  local n = 0\n  for i = 1, 3 do\n    local s = s\n    if s ~= nil then\n      n = n + #s\n    end\n  end\n" ..
      "  return n\nend\nprint(f())\n", "6")
  stands("local function f(): integer\n  local s = find()\n  if s ~= nil then\n    local s = s\n    local function p() end\n    p()\n    return #s\n  end\n" ..
      "  return 0\nend\nprint(f())\n", "2")
  -- A declaration in a loop is a new place each pass: what the pass before knew of it is not known.
  refused("local function f(): integer\n  local n = 0\n  for i = 1, 3 do\n    local s = find()\n    if i > 1 then\n      n = n + #s\n    end\n" ..
      "    if s == nil then\n      continue\n    end\n  end\n  return n\nend\n", "nil_not_allowed")
end

local function test_a_const_local_is_narrowed_like_any_other_and_cannot_be_assigned()
  stands("local function f(): integer\n  local s <const> = find()\n  if s == nil then\n    return 0\n  end\n  local g = function(): integer\n    return #s\n  end\n" ..
      "  return g()\nend\nprint(f())\n", "2")
  local r = Programs.run(PRELUDE .. "local function f()\n  local s <const> = find()\n  if s == nil then\n    return\n  end\n  s = nil\n  print(#s)\nend\n")
  assert(r.before[1] == "const_assigned", table.concat(r.before, " "))
end

-- closures ---------------------------------------------------------------------------------------------------

local function test_a_function_reads_the_facts_of_a_local_nothing_assigns_after_it_is_made()
  stands("local function f(): function(): integer\n  local s = find()\n  if s == nil then\n    error(\"none\")\n  end\n  return function(): integer\n" ..
      "    return #s\n  end\nend\nprint(f()())\n", "2")
  -- Assigned before the function is made, and tested after.
  stands("local function f(): function(): integer\n  local s = find()\n  s = find()\n  s = find()\n  if s == nil then\n    error(\"none\")\n  end\n" ..
      "  return function(): integer\n    return #s\n  end\nend\nprint(f()())\n", "2")
  -- Assigned after it is made: the function may run after the assignment, with the nil it gave.
  refused("local function f(): function(): integer\n  local s = find()\n  if s == nil then\n    error(\"none\")\n  end\n  local g = function(): integer\n" ..
      "    return #s\n  end\n  s = find()\n  return g\nend\n", "nil_not_allowed")
  -- Assigned after it in a loop that holds both, though the assignment comes first in the text.
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local total = 0\n  for i = 1, 3 do\n" ..
      "    local g = function(): integer\n      return #s\n    end\n    total = total + g()\n    s = find()\n    if s == nil then\n      return total\n    end\n" ..
      "  end\n  return total\nend\n", "nil_not_allowed")
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local total = 0\n  for i = 1, 3 do\n    s = find()\n    if s == nil then\n" ..
      "      return total\n    end\n    local g = function(): integer\n      return #s\n    end\n    total = total + g()\n  end\n  return total\nend\n", "nil_not_allowed")
  -- A function inside the function that reads it too.
  stands("local function f(): function(): function(): integer\n  local s = find()\n  if s == nil then\n    error(\"none\")\n  end\n  return function(): function(): integer\n" ..
      "    return function(): integer\n      return #s\n    end\n  end\nend\nprint(f()()())\n", "2")
end

-- joins and loops ---------------------------------------------------------------------------------------------

local function test_a_loop_keeps_a_fact_its_back_edge_keeps_and_drops_one_it_does_not()
  -- Assigned and tested again before the pass ends: the fact holds at the head.
  stands("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  for i = 1, 3 do\n    n = n + #s\n" ..
      "    s = find()\n    if s == nil then\n      return n\n    end\n  end\n  return n\nend\nprint(f())\n", "2")
  -- Assigned, and not tested again: the second pass reads the nil.
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  while n < 3 do\n    n = n + #s\n    s = find()\n  end\n" ..
      "  return n\nend\n", "narrowing_dropped")
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  repeat\n    n = n + #s\n    s = find()\n  until n > 3\n" ..
      "  return n\nend\n", "narrowing_dropped")
  -- A `continue` brings the state it left with to the head: a pass that assigns and continues loses the fact.
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  for i = 1, 3 do\n    n = n + #s\n" ..
      "    if i < 3 then\n      s = find()\n      continue\n    end\n  end\n  return n\nend\n", "narrowing_dropped")
  refused("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  repeat\n    n = n + 1\n    if n < 3 then\n" ..
      "      s = find()\n      continue\n    end\n    n = n + #s\n  until n > 3\n  return n\nend\n", "narrowing_dropped")
  -- A loop that does not assign it keeps what the entry knew.
  stands("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  local n = 0\n  for i = 1, 3 do\n    n = n + #s\n  end\n  return n\nend\nprint(f())\n", "6")
  -- `break` carries its facts out of the loop, `continue` to the end of the pass.
  stands("local function f(): integer\n  local s = find()\n  while true do\n    if s ~= nil then\n      break\n    end\n    s = find()\n  end\n  return #s\nend\nprint(f())\n", "2")
  stands("local function f(): integer\n  local n = 0\n  for i = 1, 4 do\n    local s = find()\n    if s == nil then\n      continue\n    end\n    n = n + #s\n  end\n" ..
      "  return n\nend\nprint(f())\n", "4")
  stands("local function f(): integer\n  local s = find()\n  repeat\n    if s ~= nil then\n      break\n    end\n    s = find()\n  until s ~= nil\n  return #s\nend\nprint(f())\n", "2")
  -- The loop is left by the `break` or by the pass that does not run: a for loop that may run no pass does not.
  refused("local function f(): integer\n  local s = find()\n  for i = 1, 3 do\n    s = find()\n    if s ~= nil then\n      break\n    end\n  end\n  return #s\nend\n",
    "nil_not_allowed")
  -- A `while` is left where its condition fails, a `repeat` where its condition holds.
  stands("local function f(): integer\n  local s = find()\n  while s == nil do\n    s = find()\n  end\n  return #s\nend\nprint(f())\n", "2")
  stands("local function f(): integer\n  local s = find()\n  repeat\n    s = find()\n  until s ~= nil\n  return #s\nend\nprint(f())\n", "2")
  refused("local function f(): integer\n  local s = find()\n  repeat\n    s = find()\n  until s == nil\n  return #s\nend\n", "nil_not_allowed")
  -- The condition of a `repeat` reads the locals of its body.
  stands("local function f(): integer\n  local n = 0\n  repeat\n    local s = find()\n    n = n + 1\n  until s ~= nil or n > 3\n  return n\nend\nprint(f())\n", "1")
  -- A `break` out of a loop whose test is nil leaves the facts of the test that did not break.
  refused("local function f(): integer\n  local s = find()\n  while true do\n    if s == nil then\n      break\n    end\n  end\n  return #s\nend\n", "nil_not_allowed")
end

local function test_a_loop_with_no_way_out_ends_its_block_and_a_for_loop_may_run_no_pass()
  assert(codes_of("local function f(): integer\n  while true do\n  end\nend\n") == "")
  assert(codes_of("local function f(): integer\n  while true do\n    break\n  end\nend\n") == "missing_return")
  assert(codes_of("local function f(): integer\n  for i = 1, 3 do\n    return i\n  end\nend\n") == "missing_return")
  assert(codes_of("local function f(): integer\n  repeat\n    return 1\n  until false\nend\n") == "")
end

-- reachability and definite assignment -------------------------------------------------------------------------

local function test_a_function_that_answers_values_does_not_reach_its_end()
  assert(codes_of("local function f(x: boolean): integer\n  if x then\n    return 1\n  end\nend\n") == "missing_return")
  assert(codes_of("local function f(x: boolean): integer\n  if x then\n    return 1\n  else\n    return 2\n  end\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  if x then\n    return 1\n  end\n  error(\"no\")\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  do\n    return 1\n  end\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer?\n  return nil\nend\nlocal function g(): integer...\nend\n") == "")
  assert(codes_of("local function f(): never\n  error(\"no\")\nend\n") == "")
  assert(codes_of("local function f(): never\n  print(1)\nend\n") == "missing_return")
  -- A function literal against a position that wants values is held to it as well.
  assert(codes_of("local g: function(): integer = function()\n  print(1)\nend\n") == "missing_return")
end

local function test_a_statement_after_a_jump_is_reported_once_and_checked_from_the_facts_at_the_jump()
  assert(codes_of("local function f()\n  error(\"stop\")\n  print(1)\n  print(2)\nend\n") == "unreachable")
  assert(codes_of("local function f()\n  while true do\n    break\n    print(1)\n  end\nend\n") == "unreachable")
  assert(codes_of("local function f()\n  for i = 1, 3 do\n    continue\n    print(i)\n  end\nend\n") == "unreachable")
  assert(codes_of("local function f(): integer\n  while true do\n  end\n  print(1)\n  return 1\nend\n") == "unreachable")
  -- `any` stays `any` where a test says it is not a string: the function can still reach its end.
  assert(codes_of("local function f(v: any): integer\n  if v is string then\n    return 1\n  end\nend\n") == "missing_return")
  -- A type declaration is no code.
  assert(codes_of("local function f()\n  error(\"stop\")\n  local record R\n    n: integer\n  end\nend\n") == "")
  -- The facts at the jump: a test that ended the block still holds, and an assignment after the jump still drops.
  assert(codes_of("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  error(\"stop\")\n  return #s\nend\n") == "unreachable")
  assert(codes_of("local function f(): integer\n  local s = find()\n  if s == nil then\n    return 0\n  end\n  error(\"stop\")\n  s = find()\n  return #s\nend\n") ==
      "unreachable narrowing_dropped")
  -- Code in a branch no value can take is not reported: the block starts where control does not.
  assert(codes_of("local function f(v: integer): integer\n  if type(v) == \"string\" then\n    print(1)\n  end\n  return v\nend\n") == "")
end

local function test_a_local_declared_with_no_value_is_read_only_where_every_path_assigns_it()
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  if x then\n    n = 1\n  else\n    n = 2\n  end\n  return n\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  if x then\n    n = 1\n  end\n  return n\nend\n") == "not_assigned")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  if x then\n    return 0\n  end\n  n = 1\n  return n\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  while x do\n    n = 1\n  end\n  return n\nend\n") == "not_assigned")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  while true do\n    n = 1\n    break\n  end\n  return n\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  repeat\n    n = 1\n  until x\n  return n\nend\n") == "")
  assert(codes_of("local function f(x: boolean): integer\n  local n: integer\n  for i = 1, 2 do\n    if i > 1 then\n      print(n)\n    end\n    n = i\n  end\n  return 0\nend\n") ==
      "not_assigned")
  -- A type that admits nil is nil until assigned.
  assert(codes_of("local function f(): integer?\n  local n: integer?\n  return n\nend\n") == "")
  -- Making a function reads what it names.
  assert(codes_of("local function f()\n  local n: integer\n  local g = function(): integer\n    return n\n  end\n  n = 1\n  print(g())\nend\n") == "not_assigned")
  assert(codes_of("local function f()\n  local n: integer\n  n = 1\n  local g = function(): integer\n    return n\n  end\n  print(g())\nend\n") == "")
  -- A function declared ahead and defined after the function that calls it is the same read.
  assert(codes_of("local function f()\n  local visit: function(integer)\n  local function walk(n: integer)\n    visit(n)\n  end\n  visit = walk\nend\n") ==
      "not_assigned")
  -- A name is told once.
  assert(codes_of("local function f(): integer\n  local n: integer\n  return n + n\nend\n") == "not_assigned")
end

local function test_a_local_assigned_twice_by_one_statement_leaves_the_order_open_unless_it_discards()
  assert(codes_of("local x = 1\nx, x = 2, 3\n") == "assign_repeated")
  assert(codes_of("local x = 1\nlocal y = 2\nx, y = y, x\n") == "")
  assert(codes_of("local _ = 1\n_, _ = 2, 3\n") == "")
end

-- the holes a review found --------------------------------------------------------------------------------------

local function test_an_is_test_of_an_enum_is_a_test_of_its_values()
  local head = "local enum Color \"red\" \"green\" end\nlocal function paint(c: Color): string\n  return c\nend\n"
  -- A string that is not a member is not a Color, though it is a string: the Lua tests the values.
  stands(head .. "local s: string = \"purple\"\nif s is Color then\n  print(paint(s))\nend\nprint(\"done\")\n", "done")
  stands(head .. "local s: string = \"red\"\nif s is Color then\n  print(paint(s))\nend\n", "red")
  stands(head .. "local function f(v: string | integer): string\n  if v is Color then\n    return paint(v)\n  end\n  return \"other\"\nend\n" ..
      "print(f(\"purple\"), f(\"green\"), f(3))\n", "other\tgreen\tother")
  stands(head .. "local function f(v: any): string\n  if v is Color then\n    return paint(v)\n  end\n  return \"other\"\nend\n" ..
      "print(f(\"purple\"), f(\"red\"), f(4))\n", "other\tred\tother")
  stands(head .. "local s = find()\nif s is Color then\n  print(paint(s))\nend\nprint(\"done\")\n", "done")
  -- The false edge keeps the string: only a member is taken out of it.
  assert(codes_of(head .. "local function f(v: Color | integer): integer\n  if v is Color then\n    return 1\n  end\n  return v\nend\n") == "")
  -- The fork's Lua tests the kind, which lets the string through; the check of the narrowed read sees it.
  local x = Programs.execute(PRELUDE .. head .. "local s: string = \"purple\"\nif s is Color then\n  print(paint(s))\nend\n", true, nil, true)
  local fault = x.fault
  assert(x.ran and fault ~= nil and fault:find("fact violated: s is the string purple", 1, true), tostring(fault))
  assert(x.lua:find('type(s) == "string"', 1, true) and not x.lua:find("[\"purple\"]", 1, true), x.lua)
  local y = Programs.execute(PRELUDE .. head .. "local s: string = \"purple\"\nif s is Color then\n  print(paint(s))\nend\n", true)
  assert(y.fault == nil and y.lua:find('({["red"] = true, ["green"] = true})[s] == true', 1, true), tostring(y.fault) .. y.lua)
end

local function test_is_table_tests_for_a_table_of_any_shape_and_not_for_the_library_record()
  assert(codes_of("local function f(v: any): string\n  if v is table then\n    return v.concat({ \"a\" }, \",\")\n  end\n  return \"no\"\nend\n") == "any_use")
  assert(codes_of("local function f(v: any): string\n  if v is table then\n    local c = v.concat\n  end\n  return \"no\"\nend\n") == "any_use")
  assert(codes_of("local function f(v: string | {string}): integer\n  if v is table then\n    return #v\n  end\n  return 0\nend\n") == "")
  assert(codes_of("local function f(v: string | {string}): integer\n  if v is table then\n    return 0\n  end\n  return #v\nend\n") == "")
  stands("local function f(v: any): integer\n  if v is table then\n    return 1\n  end\n  return 0\nend\nprint(f({ 1 }), f(\"x\"))\n", "1\t0")
end

local function test_a_narrowing_declaration_is_proved_of_the_argument_and_not_of_a_parameter_the_body_assigns()
  assert(codes_of("local function is_s(v: string?): v is string\n  v = \"x\"\n  return v ~= nil\nend\n"):find("narrows_unproved", 1, true) == 1)
  assert(codes_of("local function must(v: string?): asserts v is string\n  v = \"x\"\n  if v == nil then\n    error(\"no\")\n  end\nend\n"):find("narrows_unproved", 1, true) == 1)
  assert(codes_of("local function is_s(v: string?): v is string\n  if v == nil then\n    v = \"x\"\n  end\n  return v ~= nil\nend\n"):find("narrows_unproved", 1, true) == 1)
  -- A copy that the body assigns leaves the parameter as it came.
  stands("local function is_s(v: string?): v is string\n  local w = v\n  w = \"x\"\n  print(w)\n  return v ~= nil\nend\n" ..
      "local function none(): string?\n  return nil\nend\nlocal n: string? = none()\nif is_s(n) then\n  print(#n)\nend\nprint(\"done\")\n", "x,done")
end

local function test_a_test_inside_a_function_narrows_only_a_captured_local_that_is_fixed_from_then_on()
  local body = "local x: string? = find()\nlocal g = function(): integer\n  if x ~= nil then\n    return #x\n  end\n  return 0\nend\n"
  refused(body .. "x = nil\nprint(g())\n", "nil_not_allowed")
  stands(body .. "print(g())\n", "2")
  -- The same for a local of a function around the closure, and for a closure inside a closure.
  refused("local function f(x: string?): integer\n  local g = function(): integer\n    local h = function(): integer\n      if x ~= nil then\n        return #x\n      end\n" ..
      "      return 0\n    end\n    return h()\n  end\n  x = nil\n  return g()\nend\n", "nil_not_allowed")
  stands("local function f(x: string?): integer\n  local g = function(): integer\n    local h = function(): integer\n      if x ~= nil then\n        return #x\n      end\n" ..
      "      return 0\n    end\n    return h()\n  end\n  return g()\nend\nprint(f(\"abc\"), f(nil))\n", "3\t0")
end

local function test_a_function_may_assign_a_local_around_it_and_the_checker_never_narrows_that_local()
  -- The write is taken, and runs.
  stands("local n = 0\nlocal function bump()\n  n = n + 1\nend\nbump()\nbump()\nprint(n)\n", "2")
  stands("local n = 0\nlocal f = function()\n  n = 5\nend\nf()\nprint(n)\n", "5")
  stands("local n = 0\nlocal function a()\n  local function b()\n    n = 7\n  end\n  b()\nend\na()\nprint(n)\n", "7")
  -- A copy is its own local, which no function assigns, so it narrows.
  stands("local x: string? = find()\nlocal function clear()\n  x = nil\nend\nclear()\nlocal y = x\nif y ~= nil then\n  print(#y)\nelse\n" ..
      "  print(\"none\")\nend\n", "none")
  -- Its tests narrow nothing, wherever the function is made: before the test, after it, in a loop, inside another function.
  local test = "if x ~= nil then\n  print(#x)\nend\n"
  refused("local x: string? = find()\nlocal function clear()\n  x = nil\nend\n" .. test, "nil_not_allowed")
  refused("local x: string? = find()\n" .. test .. "local function clear()\n  x = nil\nend\nclear()\n", "nil_not_allowed")
  refused("local x: string? = find()\nif x then\n  print(#x)\nend\nlocal clear = function()\n  x = nil\nend\n", "nil_not_allowed")
  refused("local x: string? = find()\nif x == nil then\n  return\nend\nprint(#x)\nlocal clear = function()\n  x = nil\nend\n", "nil_not_allowed")
  refused("local x: string? = find()\nfor i = 1, 2 do\n  local clear = function()\n    x = nil\n  end\n  if x ~= nil then\n    print(#x)\n  end\n  clear()\nend\n",
    "nil_not_allowed")
  refused("local x: string? = find()\nlocal function a()\n  local function b()\n    x = nil\n  end\n  b()\nend\n" .. test, "nil_not_allowed")
  refused("local x: string? = find()\nlocal function clear()\n  x = nil\nend\nlocal g = function(): integer\n  if x ~= nil then\n    return #x\n  end\n" ..
      "  return 0\nend\n", "nil_not_allowed")
  -- Nor does what it was given when declared, or what a later assignment gives it, or the function that asserts it.
  refused("local x: string? = \"ab\"\nlocal function clear()\n  x = nil\nend\nprint(#x)\n", "nil_not_allowed")
  refused("local x: string? = nil\nlocal function clear()\n  x = nil\nend\nx = \"abc\"\nprint(#x)\n", "nil_not_allowed")
  refused("local function f(x: string?): integer\n  local function clear()\n    x = nil\n  end\n  if x ~= nil then\n    return #x\n  end\n  return 0\nend\n",
    "nil_not_allowed")
  refused("local function must(v: string?): asserts v is string\n  if v == nil then\n    error(\"no\")\n  end\nend\n" ..
      "local x: string? = find()\nlocal function clear()\n  x = nil\nend\nmust(x)\nprint(#x)\n", "nil_not_allowed")
  -- No regression: a local no function assigns narrows as before, beside one that is assigned.
  stands("local x: string? = nil\nlocal z: string? = find()\nlocal function clear()\n  x = nil\nend\nif z ~= nil then\n  print(#z)\nend\n", "2")
  stands("local x: string? = find()\nlocal g = function(): integer\n  if x ~= nil then\n    return #x\n  end\n  return 0\nend\nprint(g())\n", "2")
  stands("local x: string? = find()\nif x ~= nil then\n  x = \"abc\"\n  print(#x)\nend\n", "3")
end

-- the value of an assignment ----------------------------------------------------------------------------------

local function test_a_local_is_known_to_have_the_type_of_the_value_it_is_given()
  stands("local s: string? = \"ab\"\nprint(#s)\n", "2")
  stands("local s = find()\nif s == nil then\n  s = \"x\"\nend\nprint(#s)\n", "2")
  stands("local function f(opts: string?): integer\n  opts = opts or \"abc\"\n  return #opts\nend\nprint(f(nil), f(\"z\"))\n", "3\t1")
  refused("local s: string? = \"ab\"\ns = find()\nprint(#s)\n", "narrowing_dropped")
  refused("local s: string? = \"ab\"\ns = nil\nprint(#s)\n", "nil_not_allowed")
  -- An assignment that follows a closure is not seen by it, and one before it is.
  refused("local s: string? = \"ab\"\nlocal g = function(): integer\n  return #s\nend\ns = \"abc\"\nprint(g())\n", "nil_not_allowed")
  stands("local s: string? = nil\ns = \"abc\"\nlocal g = function(): integer\n  return #s\nend\nprint(g())\n", "3")
  -- A loop keeps it only if the back edge does.
  refused("local s: string? = \"ab\"\nfor i = 1, 2 do\n  print(#s)\n  s = find()\nend\n", "narrowing_dropped")
  -- Several values: each target takes its own.
  stands("local a: string? = nil\nlocal b: string? = nil\na, b = \"x\", \"yz\"\nprint(#a, #b)\n", "1\t2")
end

local function test_the_value_given_narrows_to_a_view_never_to_a_mut_collection()
  -- A fresh `mut {T}` held by a `{T}` stays a view: a write through it is refused.
  assert(codes_of("local xs: {integer} = {}\nxs[#xs + 1] = 1\n") == "view_written")
  assert(codes_of("local xs: {integer}? = nil\nxs = {}\nxs[#xs + 1] = 1\n") == "view_written")
  assert(codes_of("local xs: mut {integer} = {}\nxs[#xs + 1] = 1\n") == "")
  -- The join of two views is a view, and of a class and the interface it lists is the interface.
  assert(codes_of("local function f(c: boolean): integer\n  local xs: {integer}? = nil\n  if c then\n    xs = { 1 }\n  else\n    xs = { 2, 3 }\n  end\n  return #xs\nend\n") == "")
  local sized = "local interface Sized\n  size: function(self: Sized): integer\nend\nlocal class Bag is Sized\n  n: integer\n  function size(self): integer\n    return self.n\n  end\nend\n"
  assert(codes_of(sized .. "local function f(c: boolean, other: Sized): integer\n  local bag: Bag = { n = 1 }\n  local s: Sized? = nil\n  if c then\n    s = bag\n  else\n    s = other\n  end\n  return s:size()\nend\n") == "")
end

local function test_a_function_declared_ahead_that_calls_itself_is_told_to_declare_it_where_it_is_defined()
  local r = Programs.run("local function g()\n  local walk: function(integer)\n  walk = function(n: integer)\n    if n > 0 then\n      walk(n - 1)\n    end\n  end\nend\n")
  local e = r.errors[1]
  assert(e.code == "not_assigned" and e.fix:find("local function walk(...)", 1, true), e.fix)
  local other = Programs.run("local function g()\n  local walk: function(integer)\n  local function once(n: integer)\n    walk(n)\n  end\n  walk = once\nend\n")
  assert(other.errors[1].fix:find("functions of a record", 1, true), other.errors[1].fix)
end

-- the flow by code -----------------------------------------------------------------------------------------------

local function test_each_new_error_is_placed_and_says_its_fix()
  local r = Programs.run("local function f(x: boolean): integer\n  if x then\n    return 1\n  end\nend\n")
  local e = r.errors[1]
  assert(e ~= nil and e.code == "missing_return" and e.y == 2 and e.x == 3, tostring(e))
  assert(e.fix:find("end every path with a `return` of (integer)", 1, true), e.fix)
  local r2 = Programs.run("local function f()\n  local n: integer\n  local g = function(): integer\n    return n\n  end\n  n = 1\nend\n")
  local e2 = r2.errors[1]
  assert(e2 ~= nil, "an error")
  local other = e2.other
  assert(e2.code == "not_assigned" and e2.y == 3 and other ~= nil and other.y == 2, tostring(e2.code))
  assert(e2.msg:find("this function names `n`", 1, true), e2.msg)
end
