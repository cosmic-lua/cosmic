--- Tests of the calls of generic functions in [`lang.check`] ([`lang.generics`]): what each type parameter is at a call, the
--- errors when it is none or two, the bound, and a generic function used as a value. Every program the checker takes
--- is also run as the Lua [`lang.codegen`] writes ([`Programs.execute`]) and prints what it computes; a program that
--- would fail at run time if a rule had a hole is held refused beside the one that stands.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local HEAD <const> = [[
local function identity<T>(x: T): T
  return x
end
local function pick<T>(a: T, b: T): T
  return a
end
local function first<T>(xs: {T}): T?
  return xs[1]
end
local function add<T>(xs: mut {T}, v: T)
  xs[#xs + 1] = v
end
local function empty<T>(): mut {T}
  return {}
end
local function each<T>(xs: {T}, f: function(T))
  for _, x in ipairs(xs) do
    f(x)
  end
end
local interface Animal
  name: string
end
local class Dog is Animal
  name: string
end
local class Cat is Animal
  name: string
end
local function animal(): Animal
  local c: Cat = { name = "c" }
  return c
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
  local found: Types.Type? = nil
  for _, v in ipairs(r.scoped.list) do
    if v.name == name then
      found = r.result.vars[v.id] or found
    end
  end
  assert(found ~= nil, "no variable " .. name)
  return Types.display(found)
end

-- the type parameters are solved from the arguments ----------------------------------------------------------------

local function test_a_type_parameter_is_the_type_of_the_argument_that_has_it()
  assert(type_of("local n = identity(3)\n", "n") == "integer")
  assert(type_of("local s = identity(\"a\")\n", "s") == "string")
  assert(type_of("local xs: {string} = {}\nlocal v = first(xs)\n", "v") == "string?")
  assert(type_of("local m: {string: integer} = {}\nlocal v = identity(m)\n", "v") == "{string: integer}")
  stands("print(identity(3), identity(\"a\"), first({ 4, 5 }))\n", "3\ta\t4")
end

local function test_arguments_in_covariant_positions_grow_the_type_to_one_both_are_below()
  assert(type_of("local n = pick(1, 2.5)\n", "n") == "number")
  assert(type_of("local n = pick(2.5, 1)\n", "n") == "number")
  assert(type_of("local a = animal()\nlocal d: Dog = { name = \"d\" }\nlocal x = pick(d, a)\n", "x") == "Animal")
  -- Two types with no type between them have none, unless the position wants a type both are below.
  refused("local d: Dog = { name = \"d\" }\nlocal c: Cat = { name = \"c\" }\nlocal x = pick(d, c)\n", "infer_conflict")
  assert(type_of("local d: Dog = { name = \"d\" }\nlocal c: Cat = { name = \"c\" }\nlocal x: Animal = pick(d, c)\n", "x") == "Animal")
  assert(type_of("local function find(): string?\n  return nil\nend\nlocal s = find()\nlocal x = pick(s, \"a\")\n", "x") == "string?")
  stands("print(pick(1, 2.5), pick(\"a\", \"b\"))\n", "1\ta")
  -- A literal is checked last, against the type the other arguments gave.
  refused("local x = pick(1, \"a\")\n", "not_assignable")
  refused("local n = 1\nlocal s = \"a\"\nlocal x = pick(n, s)\n", "infer_conflict")
  refused("local a = animal()\nlocal n = 1\nlocal x = pick(a, n)\n", "infer_conflict")
end

local function test_a_conflict_names_both_arguments_and_the_fix()
  local r = Programs.run(HEAD .. "local n = 1\nlocal s = \"a\"\nlocal x = pick(n, s)\n")
  assert(#r.errors == 1 and r.errors[1].code == "infer_conflict", Programs.codes(r))
  local e = r.errors[1]
  assert(e.msg:find("`T` of `pick` is `integer` from argument 1 and `string` from argument 2, which have no common type", 1, true) ~= nil,
    e.msg)
  assert(e.fix:find("pass values of one type to `pick`", 1, true) ~= nil, e.fix)
  local _, lines = HEAD:gsub("\n", "")
  assert(e.y == lines + 3 and e.x == 19, tostring(e.y) .. ":" .. tostring(e.x))
end

local function test_a_mut_collection_fixes_the_type_exactly_and_the_other_arguments_are_held_to_it()
  assert(type_of("local xs: mut {string} = {}\nadd(xs, \"a\")\nlocal ok = true\n", "ok") == "boolean")
  stands("local xs: mut {number} = {}\nadd(xs, 1)\nadd(xs, 2.5)\nprint(#xs, xs[1], xs[2])\n", "2\t1\t2.5")
  -- The array is a `{number}`, so a function that adds a float to it is right to take only a number there; the
  -- argument that is a float where the array holds integers would put a float in an array of integers.
  refused("local xs: mut {integer} = {}\nadd(xs, 2.5)\n", "infer_conflict")
  -- A subtype is added to an array of its supertype, and not the reverse.
  stands("local xs: mut {Animal} = {}\nlocal d: Dog = { name = \"d\" }\nadd(xs, d)\nprint(#xs)\n", "1")
  refused("local xs: mut {Dog} = {}\nlocal a = animal()\nadd(xs, a)\n", "infer_conflict")
  -- A view is never passed where a `mut` collection is.
  refused("local xs: {string} = {}\nadd(xs, \"a\")\n", "view_as_mut")
  refused("local function clear<T>(xs: mut {T}) end\nlocal v: {string} = {}\nclear(v)\n", "view_as_mut")
  refused("local function clear<T>(xs: mut {T}) end\nlocal n = 1\nclear(n)\n", "not_assignable")
  -- Two `mut` collections of two element types are two types.
  refused("local function both<T>(a: mut {T}, b: mut {T}) end\nlocal a: mut {integer} = {}\nlocal b: mut {number} = {}\nboth(a, b)\n",
    "infer_conflict")
end

local function test_a_view_given_to_a_mut_collection_nothing_else_solves_is_told_in_the_type_it_has()
  local r = Programs.run(HEAD .. "local function clear<T>(xs: mut {T}) end\nlocal v: {string} = {}\nclear(v)\n")
  assert(#r.errors == 1 and r.errors[1].code == "view_as_mut", Programs.codes(r))
  local e = r.errors[1]
  assert(e.msg:find("the view `{string}` is not `mut {string}`", 1, true) ~= nil, e.msg)
  assert(e.fix:find("declare `v` `mut {string}`", 1, true) ~= nil, e.fix)
end

local function test_a_type_expected_that_was_reported_when_it_was_written_leaves_no_second_error()
  -- `Missing` is `unknown_type`, found before the checker runs, and the call is not also `cannot_infer`.
  local r = Programs.run(HEAD .. "local v: Missing = empty()\n")
  assert(#r.before == 1 and Programs.codes(r) == "", table.concat(r.before, " ") .. " " .. Programs.codes(r))
end

local function test_the_type_expected_fixes_a_parameter_no_argument_does()
  assert(type_of("local xs: mut {string} = empty()\n", "xs") == "mut {string}")
  assert(type_of("local ys: mut {string}? = empty()\n", "ys") == "mut {string}?")
  assert(type_of("local n: number = identity(1)\n", "n") == "number")
  stands("local xs: mut {string} = empty()\nadd(xs, \"a\")\nprint(#xs)\n", "1")
  -- Nothing says what the array holds.
  refused("local xs = empty()\n", "cannot_infer")
  refused("empty()\n", "cannot_infer")
  -- A result that is not the type expected is refused, whatever was solved.
  refused("local n: integer = identity(2.5)\n", "not_assignable")
  refused("local xs: mut {string} = empty()\nlocal ys: mut {integer} = xs\n", "invariant_mut")
end

local function test_the_type_expected_picks_the_exact_type_that_the_arguments_are_below()
  assert(type_of("local function wrap<T>(x: T): mut {T}\n  return { x }\nend\nlocal xs: mut {number} = wrap(1)\n", "xs") ==
      "mut {number}")
  refused("local function wrap<T>(x: T): mut {T}\n  return { x }\nend\nlocal xs: mut {string} = wrap(1)\n", "invariant_mut")
end

local function test_an_unsolved_parameter_is_reported_once_with_the_fix()
  local r = Programs.run(HEAD .. "local xs = empty()\n")
  assert(#r.errors == 1 and r.errors[1].code == "cannot_infer", Programs.codes(r))
  local e = r.errors[1]
  assert(e.msg:find("`empty` is generic, and nothing fixes its type parameter `T`", 1, true) ~= nil, e.msg)
  assert(e.fix:find("type the result", 1, true) ~= nil and e.fix:find("local v: T = empty(...)", 1, true) ~= nil, e.fix)
  -- A mistake in an argument already reported does not report the parameter it should have given.
  local bad = Programs.run(HEAD .. "local xs = first(nope)\n")
  assert(Programs.codes(bad) == "", Programs.codes(bad))
  refused("local n: integer = 1\nlocal xs = first(n)\n", "not_assignable")
end

-- function literals ---------------------------------------------------------------------------------------------

local function test_a_function_literal_takes_its_parameter_types_from_the_instance()
  stands("local names: {string} = { \"a\", \"bc\" }\neach(names, function(n) print(#n) end)\n", "1,2")
  refused("local names: {string} = { \"a\" }\neach(names, function(n) print(n + 1) end)\n", "operand_type")
  refused("local names: {string} = { \"a\" }\neach(names, function(n: integer) print(n) end)\n", "not_assignable")
  -- A literal whose parameters nothing fixes has no type to be checked against.
  refused("local function run<T>(f: function(T)) end\nrun(function(x) print(x) end)\n", "cannot_infer")
  stands("local function run<T>(f: function(T)): T?\n  return nil\nend\nlocal v = run(function(x: string) print(x) end)\n" ..
      "print(v)\n", "nil")
end

local function test_a_literal_that_gives_a_parameter_nothing_else_does_is_typed_alone()
  assert(type_of("local ys = identity({ 1, 2 })\n", "ys") == "mut {integer}")
  assert(type_of("local s = identity(\"a\")\n", "s") == "string")
  stands("for _, x in ipairs({ \"a\", \"b\" }) do print(x) end\n", "a,b")
end

local function test_an_argument_at_a_position_without_a_type_parameter_is_given_that_type_to_expect()
  -- `empty` has no argument to solve its parameter from: the position of `take` that wants `{integer}` does.
  local head = "local function take<T>(x: T, xs: {integer}): T\n  return x\nend\n"
  stands(head .. "print(take(\"a\", empty()))\n", "a")
  assert(codes_of(head .. "local r = take(\"a\", empty())\n") == "")
end

local function test_two_upper_bounds_meet_in_the_narrower_and_a_union_is_matched_by_what_its_other_members_leave()
  -- Both functions take the parameter: the type it has to be is below what each takes, so the narrower one.
  local both = "local function fa(a: Animal) end\nlocal function fd(d: Dog) end\n" ..
    "local function use2<T>(f: function(T), g: function(T)): T?\n  return nil\nend\n"
  assert(type_of(both .. "local r = use2(fa, fd)\n", "r") == "Dog?")
  assert(type_of(both .. "local r = use2(fd, fa)\n", "r") == "Dog?")
  -- `string` is taken by the plain member of `{A} | string`, and what is left of the argument gives `A`.
  local head = "local function head<A>(x: {A} | string): A?\n  return nil\nend\n"
  assert(type_of(head .. "local function f(u: {integer} | string)\n  local v = head(u)\nend\n", "v") == "integer?")
end

--- The names of the variables of type `invalid` in `body` when the checker reports nothing, which is a hole.
local function silent_invalid(body: string): {string}
  local r = Programs.run(HEAD .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  local found: mut {string} = {}
  if #r.errors == 0 then
    for _, v in ipairs(r.scoped.list) do
      local t = r.result.vars[v.id]
      if t ~= nil and t.tag == "invalid" then
        found[#found + 1] = v.name
      end
    end
  end
  return found
end

local function test_a_union_of_shapes_is_solved_by_its_members_or_refused_and_never_an_invalid_that_is_taken_for_any_type()
  -- The members agree on a type both are below, so the call has it and runs.
  stands("local function f(u: {integer} | {number})\n  print(first(u))\nend\nlocal xs: {integer} = { 1 }\nf(xs)\n", "1")
  assert(type_of("local function f(u: {integer} | {number})\n  local seen = first(u)\nend\n", "seen") == "number?")
  -- They have no common type: one error, and the element is not taken for a string by the line after.
  local shout = "local function shout(u: {integer} | {string}): string\n  for _, v in ipairs(u) do\n    local s: string = v\n" ..
    "    return s:upper()\n  end\n  return \"\"\nend\nlocal nums: {integer} = { 1 }\nprint(shout(nums))\n"
  local r = Programs.run(HEAD .. shout)
  assert(#r.errors == 1 and r.errors[1].code == "infer_conflict", Programs.codes(r))
  assert(r.errors[1].msg:find("`T` of `ipairs` is `string` from argument 1 and `integer` from another type in it", 1, true) ~= nil,
    r.errors[1].msg)
  assert(r.errors[1].fix:find("narrow argument 1 to one of its types first", 1, true) ~= nil, r.errors[1].fix)
  -- The same for a union of functions, of maps, of generics, and of a mut collection.
  refused("local function f(g: (function(): integer) | (function(): string))\n  each({ 1 }, g)\n  local x = identity(g)\nend\n" ..
      "local function h(u: {integer} | {string})\n  local x = first(u)\n  local s: string = x\nend\n", "not_assignable infer_conflict")
  refused("local function f(m: {string: integer} | {integer: string})\n  for k, v in pairs(m) do\n    local s: string = k\n  end\nend\n",
    "infer_conflict infer_conflict")
  refused("local function f(u: mut {integer} | mut {string})\n  add(u, 1)\nend\n", "infer_conflict")
  refused("local class Box<T>\n  value: T\nend\nlocal function open<T>(b: Box<T>): T\n  return b.value\nend\n" ..
      "local function f(b: Box<integer> | Box<string>)\n  local x = open(b)\nend\n", "infer_conflict")
  -- A parameter that is a union of shapes with a type parameter in each says nothing of either.
  local two = "local function two<T, U>(x: {T} | {U}): T?\n  return nil\nend\nlocal b: {integer} = { 1 }\n"
  local hole = Programs.run(HEAD .. two .. "local c = two(b)\n")
  assert(#hole.errors == 1 and hole.errors[1].code == "cannot_infer", Programs.codes(hole))
  assert(hole.errors[1].msg:find("parameters `T`, `U` get no type from the arguments", 1, true) ~= nil, hole.errors[1].msg)
  assert(#silent_invalid(two .. "local c = two(b)\n") == 0)
  -- No program of these has a variable of type `invalid` that nothing was reported for.
  for _, body in ipairs({
      "local function f(u: {integer} | {string})\n  local x = first(u)\nend\n",
      "local function f(u: {integer} | {string})\n  for _, v in ipairs(u) do end\nend\n",
      "local function f(m: {string: integer} | {integer: string})\n  for k, v in pairs(m) do end\nend\n",
      "local function f(g: (function(): integer) | (function(): string))\n  local x = identity(g)\n  each({ 1 }, g)\nend\n",
      "local function f(u: ({integer} | {number})?)\n  local x = first(u)\nend\n",
  }) do
    local found = silent_invalid(body)
    assert(#found == 0, table.concat(found, " ") .. " is invalid and nothing is reported in\n" .. body)
  end
end

local function test_an_instance_that_makes_an_array_of_optionals_is_refused_as_the_annotation_is()
  local head = "local function wrap<T>(x: T): mut {T}\n  return { x }\nend\n"
  stands(head .. "local xs = wrap(5)\nprint(#xs, xs[1])\n", "1\t5")
  refused(head .. "local function f(m: integer?)\n  local xs = wrap(m)\nend\n", "array_of_optional")
  refused(head .. "local xs = wrap(nil)\n", "array_of_optional")
  refused("local function table_of<K, V>(k: K, v: V): {K: V}\n  return { [k] = v }\nend\n" ..
      "local function f(m: string?)\n  local t = table_of(1, m)\nend\n", "array_of_optional")
  -- An optional that is not in an element stands.
  assert(type_of("local function f(m: integer?)\n  local seen = identity(m)\nend\n", "seen") == "integer?")
end

-- bounds ------------------------------------------------------------------------------------------------------

local function test_a_type_argument_has_to_meet_the_bound_of_its_parameter()
  local head = "local interface Named\n  name: string\nend\nlocal class Person is Named\n  name: string\nend\n" ..
    "local record Plain\n  name: string\nend\n" ..
    "local function label<T is Named>(x: T): string\n  return x.name\nend\n"
  stands(head .. "local p: Person = { name = \"ann\" }\nprint(label(p))\n", "ann")
  refused(head .. "local p: Plain = { name = \"ann\" }\nprint(label(p))\n", "bound_unmet")
  refused(head .. "print(label(1))\n", "bound_unmet")
  local r = Programs.run(HEAD .. head .. "local p: Plain = { name = \"ann\" }\nprint(label(p))\n")
  local e = r.errors[#r.errors]
  assert(e.code == "bound_unmet" and e.msg:find("`Plain` is the type parameter `T` of `label`, which is bounded by `Named`", 1, true) ~= nil,
    e.msg)
  assert(e.fix:find("list the interface in the declaration of `Plain` (`is Named`)", 1, true) ~= nil, e.fix)
  -- A type variable of the caller meets the bound through its own.
  stands(head .. "local function outer<U is Named>(x: U): string\n  return label(x)\nend\n" ..
      "local p: Person = { name = \"bo\" }\nprint(outer(p))\n", "bo")
  refused(head .. "local function outer<U>(x: U): string\n  return label(x)\nend\n", "bound_unmet")
end

-- the library: assert, table.insert, ipairs ----------------------------------------------------------------------

local function test_assert_answers_its_argument_without_nil_and_the_message_too()
  assert(type_of("local function find(): string?\n  return \"a\"\nend\nlocal s = assert(find())\n", "s") == "string")
  assert(type_of("local function find(): string?\n  return \"a\"\nend\nlocal s, m = assert(find(), \"no\")\n", "m") == "string")
  stands("local function find(): string?\n  return \"ab\"\nend\nprint(#assert(find()))\n", "2")
  stands("assert(true)\nassert(1 == 1, \"one\")\nprint(assert(3))\n", "3")
  refused("local function find(): string?\n  return \"a\"\nend\nlocal n: integer = assert(find())\n", "not_assignable")
end

local function test_table_sort_takes_a_comparator_or_elements_that_less_than_orders()
  stands("local ns: mut {integer} = { 3, 1, 2 }\ntable.sort(ns)\nprint(ns[1], ns[3])\n", "1\t3")
  stands("local ss: mut {string} = { \"b\", \"a\" }\ntable.sort(ss)\nprint(ss[1])\n", "a")
  stands("local ds: mut {Dog} = { { name = \"z\" }, { name = \"a\" } }\ntable.sort(ds, function(a: Dog, b: Dog): boolean " ..
      "return a.name < b.name end)\nfor _, d in ipairs(ds) do\n  print(d.name)\nend\n", "a,z")
  -- Dogs, booleans and a mixed array are not ordered by `<`: the run would fail with "attempt to compare".
  refused("local ds: mut {Dog} = { { name = \"z\" }, { name = \"a\" } }\ntable.sort(ds)\n", "overload_none")
  refused("local bs: mut {boolean} = { true, false }\ntable.sort(bs)\n", "overload_none")
  refused("local ms: mut {integer | string} = { 1, \"a\" }\ntable.sort(ms)\n", "overload_none")
end

local function test_table_insert_takes_an_array_that_changes_and_the_element_of_it()
  stands("local xs: mut {integer} = {}\ntable.insert(xs, 1)\ntable.insert(xs, 1, 0)\nprint(#xs, xs[1], xs[2])\n", "2\t0\t1")
  refused("local xs: mut {integer} = {}\ntable.insert(xs, \"a\")\n", "overload_none")
  refused("local xs: {integer} = {}\ntable.insert(xs, 1)\n", "overload_none")
  refused("local xs: mut {integer}? = nil\ntable.insert(xs, 1)\n", "overload_none")
  stands("local xs: mut {string} = { \"b\", \"a\" }\ntable.sort(xs)\nprint(xs[1])\n", "a")
end

local function test_ipairs_and_pairs_give_the_element_and_the_key_and_value_types()
  assert(type_of("local xs: {string} = {}\nfor _, x in ipairs(xs) do\n  local seen = x\nend\n", "seen") == "string")
  assert(type_of("local m: {string: integer} = {}\nfor k, v in pairs(m) do\n  local seen = v\nend\n", "seen") == "integer")
  stands("local total = 0\nfor i, x in ipairs({ 5, 6 }) do total = total + i * x end\nprint(total)\n", "17")
  refused("local n = 3\nfor _, x in ipairs(n) do end\n", "not_assignable")
end

-- a generic function as a value --------------------------------------------------------------------------------------

local function test_a_generic_function_is_a_value_of_the_function_types_its_instance_meets()
  stands("local f: function(integer): integer = identity\nprint(f(4))\n", "4")
  stands("local function twice(f: function(string): string, s: string): string\n  return f(f(s))\nend\nprint(twice(identity, \"x\"))\n", "x")
  refused("local f: function(integer): string = identity\n", "not_assignable")
  refused("local f: function(): integer = identity\n", "not_assignable")
  -- A generic function that is called through a local is solved at each call.
  stands("local g = identity\nprint(g(1), g(\"a\"))\n", "1\ta")
end

local function test_a_generic_method_is_solved_with_its_receiver()
  local head = "local record Box<T>\n  value: T\nend\n" ..
    "local function get<T>(b: Box<T>): T\n  return b.value\nend\n" ..
    "local function set<T>(b: Box<T>, v: T): Box<T>\n  return { value = v }\nend\n"
  assert(type_of(head .. "local b: Box<string> = { value = \"a\" }\nlocal s = get(b)\n", "s") == "string")
  stands(head .. "local b: Box<string> = { value = \"a\" }\nprint(get(set(b, \"z\")))\n", "z")
  refused(head .. "local b: Box<string> = { value = \"a\" }\nlocal c = set(b, 1)\n", "infer_conflict")
end

-- soundness ------------------------------------------------------------------------------------------------------

local function test_a_generic_call_cannot_put_the_wrong_value_in_a_collection()
  -- `add` stores into the array it is given: a value of the supertype would be an animal in an array of dogs.
  refused("local dogs: mut {Dog} = {}\nlocal a = animal()\nadd(dogs, a)\n", "infer_conflict")
  -- A view of dogs is not an array that may be added to, even of animals.
  refused("local dogs: {Dog} = {}\nlocal a = animal()\nadd(dogs, a)\n", "view_as_mut")
  -- `any` is not a type argument, and is not passed through one.
  refused("local function f(v: any)\n  local x = identity(v)\nend\n", "")
end

local function test_a_generic_function_inside_another_is_solved_with_the_variables_of_both()
  stands("local function outer<T>(x: T): T\n  local function inner<U>(a: T, b: U): U\n    return b\n  end\n  local n = inner(x, 1)\n" ..
      "  local s = inner(x, \"s\")\n  print(n, s)\n  return x\nend\nprint(outer(5))\n", "1\ts,5")
  -- The outer variable is not solved by the inner call: an argument that is not a `T` is refused.
  refused("local function outer<T>(x: T, y: integer)\n  local function inner<U>(a: T, b: U): U\n    return b\n  end\n  local n = inner(y, 1)\nend\n",
    "not_assignable")
end

local function test_a_nil_argument_makes_the_parameter_optional_and_the_result_is_held_to_it()
  refused("local function find(): integer?\n  return nil\nend\nlocal n: integer = pick(find(), 3)\n", "nil_not_allowed")
  assert(type_of("local function find(): integer?\n  return nil\nend\nlocal n = pick(find(), 3)\n", "n") == "integer?")
  assert(type_of("local n = pick(nil, 3)\n", "n") == "integer?")
end

local function test_a_generic_function_is_not_a_value_of_a_type_its_parameters_cannot_meet()
  refused("local function two<T>(a: T, b: T): T\n  return a\nend\nlocal f: function(integer, string): integer = two\n", "not_assignable")
  refused("local function put<T>(xs: mut {T}, v: T) end\nlocal f: function({integer}, integer) = put\n", "view_as_mut")
  stands("local function put<T>(xs: mut {T}, v: T)\n  xs[#xs + 1] = v\nend\nlocal f: function(mut {integer}, integer) = put\n" ..
      "local xs: mut {integer} = {}\nf(xs, 4)\nprint(#xs, xs[1])\n", "1\t4")
end

local function test_an_invariant_position_requires_the_exact_type_and_a_function_argument_the_type_it_takes()
  local head = "local record Box<T>\n  value: T\nend\nlocal function put<T>(b: Box<T>, v: T) end\n"
  stands(head .. "local d: Dog = { name = \"d\" }\nlocal b: Box<Dog> = { value = d }\nput(b, d)\nprint(b.value.name)\n", "d")
  -- The box of dogs is exactly that, so an animal does not go in it.
  refused(head .. "local d: Dog = { name = \"d\" }\nlocal b: Box<Dog> = { value = d }\nlocal a = animal()\nput(b, a)\n", "infer_conflict")
  -- A function that takes only dogs is not called with each animal.
  refused("local function dogs(d: Dog) end\nlocal many = { animal() }\neach(many, dogs)\n", "infer_conflict")
  stands("local function show(a: Animal)\n  print(a.name)\nend\nlocal d: Dog = { name = \"d\" }\neach({ d }, show)\n", "d")
end

-- A generic function passed where a function is wanted is instantiated from the values the callee passes it, so what it answers
-- is a type, not a parameter nothing fixes (`invalid`, which every type accepts); and an overload whose type parameter
-- nothing solves is no candidate. On main the `pcall`, `xpcall`, `coroutine.wrap` and `coroutine.create` cases below are
-- accepted (the result is `invalid`); the `Box` case and the `pcall` of a function that is not generic are refused there
-- and must stay so.
local function test_a_generic_function_passed_to_a_callee_answers_a_type_and_not_any_type()
  local head = "local function id<T>(x: T): T\n  return x\nend\n"
  refused(head .. "local n: integer = 1\nlocal ok, r = pcall(id, n)\nlocal s: string = r\nprint(ok, s)\n", "any_use")
  refused(head .. "local ok, r = pcall(id, 1)\nlocal s: string = r\nprint(ok, s)\n", "any_use")
  refused(head .. "local function f(v: any): {integer}?\n  local ok, r = pcall(id, v)\n  if ok then return r end\n  return nil\nend\nprint(f)\n",
    "any_use")
  -- an overloaded callee whose type parameter the generic function leaves unsolved is no candidate
  refused(head .. "local co = coroutine.wrap(id)\nlocal v = co()\nlocal w: string = v\nprint(w)\n", "overload_none")
  refused(head .. "local co = coroutine.create(id)\nlocal ok, v = coroutine.resume(co)\nlocal w: string = v\nprint(ok, w)\n",
    "overload_none")
  refused(head .. "local function getid(): function<T>(T): T\n  return id\nend\nlocal co = coroutine.wrap(getid())\n" ..
      "local v = co()\nlocal w: string = v\nprint(w)\n", "overload_none")
  -- a generic callee that takes its parameter from a type in the function's parameters says so, as on main: the
  -- instance of `id` is not taken from a parameter that mentions `invalid`
  refused(head .. "local record Box<Y>\n  v: Y\nend\nlocal function app<Y, R>(f: function(Box<Y>): R): Y\n  error(\"x\")\nend\n" ..
      "local r = app(id)\nlocal s: string = r\nprint(s)\n", "cannot_infer")
  -- a protected call of a function that is not generic was refused already; `xpcall` of a generic function was not
  refused("local function one(x: integer): integer\n  return x\nend\nlocal ok, r = pcall(one, 1)\nlocal n: integer = r\nprint(ok, n)\n",
    "any_use")
  refused(head .. "local function h(e: any): any\n  return e\nend\nlocal ok, r = xpcall(id, h, 1)\nlocal s: string = r\nprint(ok, s)\n",
    "any_use")
  -- a value checked first is the type it was checked to
  stands(head .. "local ok, r = pcall(id, 1)\nif r is integer then print(r + 1) end\nprint(ok)\n", "2,true")
end

-- An `invalid` argument stands for a mistake reported where it was made, and silences only the type parameters it was found
-- for: the others are reported if nothing solves them. On main one invalid argument silenced the whole call.
local function test_an_invalid_argument_silences_only_the_type_parameters_it_was_found_for()
  local head = "local function both<T, U>(a: T, b: {T} | {U}): T\n  return a\nend\n" ..
    "local m: {string: integer} = { k = 1 }\nlocal bad = m.k.nothing\n"
  -- the call has a parameter the invalid argument did not touch and nothing solves
  refused(head .. "local ys: {integer} = { 1 }\nlocal r = both(bad, ys)\nprint(r)\n", "map_field cannot_infer")
  -- a hole only the invalid argument could have filled is not reported again
  refused(head .. "for _, v in ipairs(bad) do\n  print(v)\nend\nlocal t = pairs(bad)\nprint(t)\n", "map_field")
  refused(head .. "local co = coroutine.status(bad)\nprint(co)\n", "map_field")
end

-- A generic function passed to an overloaded callee, taken from the values the callee passes it, says which bound a type
-- fails to meet, where it used to be `overload_none`.
-- An `invalid` that is only a part of what is found for a variable marks it too: the type the call is expected to have
-- (`{R.Item}`, a field that is no type), an element.
local function test_an_invalid_part_of_what_is_found_marks_the_variable()
  local declared = Programs.run(HEAD .. "local record R\n  Item: string\nend\nlocal function make<T>(): {T}\n  return {}\nend\n" ..
      "local xs: {R.Item} = make()\nprint(xs)\n")
  assert(#declared.before == 1 and declared.before[1]:find("member_missing", 1, true) ~= nil,
    table.concat(declared.before, " "))
  assert(Programs.codes(declared) == "", Programs.codes(declared))
  local head = "local m: {string: integer} = { k = 1 }\nlocal bad = m.k.nothing\n"
  refused(head .. "for _, v in ipairs({ bad }) do\n  print(v)\nend\n", "map_field")
end

local function test_a_bound_a_passed_generic_function_does_not_meet_is_bound_unmet()
  local head = "local interface Named\n  name: string\nend\nlocal record Plain\n  name: string\nend\n" ..
    "local function label<T is Named>(x: T): string\n  return x.name\nend\nlocal p: Plain = { name = \"ann\" }\n"
  refused(head .. "local ok, r = pcall(label, p)\nprint(ok, r)\n", "bound_unmet")
  refused(head .. "local function h(e: any): any\n  return e\nend\nlocal ok, r = xpcall(label, h, p)\nprint(ok, r)\n",
    "bound_unmet")
  stands("local interface Named\n  name: string\nend\nlocal class Person is Named\n  name: string\nend\n" ..
      "local function label<T is Named>(x: T): string\n  return x.name\nend\nlocal p: Person = { name = \"ann\" }\n" ..
      "local ok, r = pcall(label, p)\nprint(ok, r is string)\n", "true\ttrue")
end

local function test_an_iterator_that_is_a_generic_function_is_solved_by_the_state_and_the_control_value()
  local head = "local function step<T>(xs: {T}, at: integer?): (integer?, T?)\n  return nil, nil\nend\n"
  assert(type_of(head .. "local names: {string} = { \"a\" }\nfor i, v in step, names, nil do\n  local seen = v\nend\n", "seen") == "string?")
  assert(type_of(head .. "local names: {string} = { \"a\" }\nfor i, v in step, names, nil do\n  local seen = i\nend\n", "seen") == "integer")
  stands(head .. "local names: {string} = { \"a\" }\nfor i, v in step, names, nil do\n  print(i)\nend\nprint(\"done\")\n", "done")
  refused(head .. "for i, v in step, 3, nil do\nend\n", "not_assignable")
end

local function test_a_class_gives_the_type_arguments_of_the_interface_it_lists_and_a_record_its_array_part()
  local head = "local interface Source<T>\n  last: T\nend\nlocal class Counter is Source<integer>\n  last: integer\nend\n" ..
    "local function latest<T>(s: Source<T>): T\n  return s.last\nend\nlocal c: Counter = { last = 5 }\n"
  assert(type_of(head .. "local n = latest(c)\n", "n") == "integer")
  stands(head .. "print(latest(c))\n", "5")
  refused(head .. "local record Plain\n  last: integer\nend\nlocal p: Plain = { last = 1 }\nlocal n = latest(p)\n", "not_assignable")
  -- A record with an array part is a view of that part.
  local rows = "local record Rows is {string}\n  count: integer\nend\nlocal r: Rows = { count = 1, \"a\" }\n"
  assert(type_of(rows .. "local v = first(r)\n", "v") == "string?")
end
