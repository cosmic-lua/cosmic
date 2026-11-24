--- Tests of the calls of generic functions in [`lang.check`] ([`lang.generics`]): what each type parameter is at a call, the
--- errors when it is none or two, the bound, and a generic function used as a value. Every program the checker takes
--- is also run as the Lua [`lang.codegen`] writes ([`Programs.execute`]) and prints what it computes; a program that
--- would fail at run time if a rule had a hole is held refused beside the one that stands.
local Array = require("cosmic.array")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

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

--- [`Programs.codes_of`] of `body` after the head.
local function codes_of(body: string): string
  return Programs.codes_of(HEAD .. body)
end

--- [`Programs.stands`] of `body` after the head.
local function stands(body: string, want: string)
  Programs.stands(HEAD .. body, want)
end

--- [`Programs.refused`] of `body` after the head.
local function refused(body: string, codes: string)
  Programs.refused(HEAD .. body, codes)
end

--- [`Programs.type_of`] of `body` after the head.
local function type_of(body: string, name: string): string
  return Programs.type_of(HEAD .. body, name)
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
  -- The assertion above holds that there is exactly one error.
  local e = Array.at(r.errors, 1)
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
  -- The assertion above holds that there is exactly one error.
  local e = Array.at(r.errors, 1)
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
  -- The assertion above holds that there is exactly one error.
  local e = Array.at(r.errors, 1)
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
  -- The assertion above holds that there is exactly one error.
  local conflict = Array.at(r.errors, 1)
  assert(conflict.msg:find("`T` of `ipairs` is `string` from argument 1 and `integer` from another type in it", 1, true) ~= nil,
    conflict.msg)
  assert(conflict.fix:find("narrow argument 1 to one of its types first", 1, true) ~= nil, conflict.fix)
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
  local gap = Array.at(hole.errors, 1) -- the assertion above holds that there is exactly one error
  assert(gap.msg:find("parameters `T`, `U` get no type from the arguments", 1, true) ~= nil, gap.msg)
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
  refused("local function table_of<K is Key, V>(k: K, v: V): {K: V}\n  return { [k] = v }\nend\n" ..
      "local function f(m: string?)\n  local t = table_of(1, m)\nend\n", "array_of_optional")
  -- An optional that is not in an element stands.
  assert(type_of("local function f(m: integer?)\n  local seen = identity(m)\nend\n", "seen") == "integer?")
end

-- bounds ------------------------------------------------------------------------------------------------------

local function test_a_type_argument_has_to_meet_the_bound_of_its_parameter()
  local head = "local interface Named\n  name: string\nend\nlocal class Person is Named\n  name: string\nend\n" ..
    "local record Plain\n  title: string\nend\n" ..
    "local function label<T is Named>(x: T): string\n  return x.name\nend\n"
  stands(head .. "local p: Person = { name = \"ann\" }\nprint(label(p))\n", "ann")
  refused(head .. "local p: Plain = { title = \"ann\" }\nprint(label(p))\n", "bound_unmet")
  refused(head .. "print(label(1))\n", "bound_unmet")
  local r = Programs.run(HEAD .. head .. "local p: Plain = { title = \"ann\" }\nprint(label(p))\n")
  -- The program is refused, so `errors` is not empty.
  local e = Array.at(r.errors, #r.errors)
  assert(e.code == "bound_unmet" and e.msg:find("`Plain` is the type parameter `T` of `label`, which is bounded by `Named`", 1, true) ~= nil,
    e.msg)
  assert(e.fix:find("declare `name: string` in `Plain`, as the interface does", 1, true) ~= nil, e.fix)
  -- A record with the interface's fields meets the bound with no listing.
  stands(head .. "local record Titled\n  name: string\nend\nlocal t: Titled = { name = \"bo\" }\nprint(label(t))\n", "bo")
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

-- The shape of [`cosmic.shape`]: a spec names the type of what it checks, so that no annotation chooses the type of an answer
-- and a list whose elements may be missing cannot be an array.
local SPEC <const> = [[
local record Spec<T>
  check: function(value: any, path: string): T?, string
end
local INT: Spec<integer> = { check = function(_v: any, _p: string): integer?, string return nil, "" end }
local STR: Spec<string> = { check = function(_v: any, _p: string): string?, string return nil, "" end }
local function list<A>(_of: Spec<A>): Spec<{A}>
  return { check = function(_v: any, _p: string): {A}?, string return nil, "" end }
end
local function optional<A>(_of: Spec<A>): Spec<A?>
  return { check = function(_v: any, _p: string): A?, string return nil, "" end }
end
local function sparse_list<A>(_of: Spec<A?>): Spec<{integer: A}>
  return { check = function(_v: any, _p: string): {integer: A}?, string return nil, "" end }
end
local function into<T>(spec: Spec<T>): T?
  local out, _ = spec.check(nil, "$")
  return out
end
]]

local function test_a_spec_gives_the_type_of_its_answer_and_a_list_of_optional_elements_is_no_array()
  stands(SPEC .. "local xs: {integer}? = into(list(INT))\nprint(xs == nil)\n", "true")
  -- the annotation cannot say another type than the spec's
  refused(SPEC .. "local xs: {string}? = into(list(INT))\n", "not_assignable")
  -- an array holds no hole, so a list of elements that may be missing does not compile
  refused(SPEC .. "local xs = list(optional(INT))\nprint(xs)\n", "array_of_optional")
  -- its answer is a map, which has no length and whose read is optional
  stands(SPEC .. "local slots = into(sparse_list(optional(INT)))\nprint(slots == nil)\n", "true")
  refused(SPEC .. "local slots = into(sparse_list(optional(INT)))\nif slots ~= nil and #slots > 0 then print(slots[1]) end\n",
    "operand_type")
  refused(SPEC .. "local slots = into(sparse_list(optional(INT)))\nif slots ~= nil then local n: integer = slots[1] print(n) end\n",
    "index_may_be_nil")
  -- a spec only answers its type, so it is covariant: a spec of a string is a spec of a string that may be nil, and
  -- its sparse list is a map of strings
  refused(SPEC .. "local xs = sparse_list(STR)\nlocal m: {integer: string}? = into(xs)\nprint(m)\n", "")
end

-- The check `record_of` takes is a function the checker types too: a call that passes one of its own, by whatever route it
-- is written, names the type the check answers and no other.
local function test_a_record_check_passed_to_record_of_must_answer_its_record()
  local head = SPEC .. "local record Typed<T>\n  make: function(strict: boolean): Spec<T>\nend\n" ..
    "local function record_of<T>(_name: string, make: function(strict: boolean): Spec<T>): Typed<T>\n" ..
    "  return { make = make }\nend\n" ..
    "local record Row\n  id: string\nend\n"
  refused(head .. "local t: Typed<Row> = record_of(\"Row\", function(_s: boolean): Spec<integer>\n" ..
      "  return INT\nend)\n", "not_assignable")
  stands(head .. "local t: Typed<integer> = record_of(\"Row\", function(_s: boolean): Spec<integer>\n" ..
      "  return INT\nend)\nprint(type(t))\n", "table")
end

-- A spec is a check, so one written by hand is a function the checker types: it answers its `T` or it does not compile,
-- and no spec of one type is a spec of another.
local function test_a_spec_written_by_hand_must_answer_its_type()
  -- a check that answers a string is no check of an integer
  refused(SPEC .. "local f: Spec<integer> = { check = function(_v: any, _p: string): string?, string return nil, \"\" end }\n",
    "not_assignable")
  -- nor can it answer the untrusted value it was handed
  refused(SPEC .. "local f: Spec<integer> = { check = function(v: any, _p: string): integer?, string return v, \"\" end }\n",
    "any_use")
  -- nor take a cast to say so
  refused(SPEC .. "local f: Spec<integer> = { check = function(v: any, _p: string): integer?, string return v as integer, \"\" end }\n",
    "cast_refused")
  -- a spec of one type is not a spec of another, a table of untrusted values included
  refused(SPEC .. "local a: Spec<{string: any}> = { check = function(_v: any, _p: string): {string: any}?, string return nil, \"\" end }\n" ..
      "local b: Spec<{integer}> = a\n", "not_assignable")
  -- a node beside the check is a field the record does not have
  refused(SPEC .. "local f: Spec<integer> = { node = 1, check = function(_v: any, _p: string): integer?, string return nil, \"\" end }\n", "literal_unknown")
  -- one that answers its type is one
  stands(SPEC .. "local f: Spec<integer> = { check = function(v: any, _p: string): integer?, string\n" ..
      "  if v is integer then return v, \"\" end\n  return nil, \"no\"\nend }\nprint(into(f))\n", "nil")
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

-- An `invalid` that is only a part of what is found for a variable marks it too: the type the call is expected to have
-- (`{R.Item}`, a field that is no type), an element, a member of a union.
local function test_an_invalid_part_of_what_is_found_marks_the_variable()
  local declared = Programs.run(HEAD .. "local record R\n  Item: string\nend\nlocal function make<T>(): {T}\n  return {}\nend\n" ..
      "local xs: {R.Item} = make()\nprint(xs)\n")
  assert(#declared.before == 1 and declared.before[1]:find("member_missing", 1, true) ~= nil,
    table.concat(declared.before, " "))
  assert(Programs.codes(declared) == "", Programs.codes(declared))
  local head = "local m: {string: integer} = { k = 1 }\nlocal bad = m.k.nothing\n"
  refused(head .. "for _, v in ipairs({ bad }) do\n  print(v)\nend\n", "map_field")
  -- a union with an invalid member stands for the mistake in it: only the declaration is reported, and a variable
  -- the union did not touch is still reported where nothing fixes it
  local union = "local record R\n  Item: string\nend\nlocal function both<T, U>(a: T, b: {T} | {U}): T\n  return a\nend\n"
  local marked = Programs.run(HEAD .. union .. "local u: {integer} | R.Item\nlocal r = both(1, u)\nprint(r)\n")
  assert(#marked.before == 1 and marked.before[1]:find("member_missing", 1, true) ~= nil, table.concat(marked.before, " "))
  assert(Programs.codes(marked) == "", Programs.codes(marked))
  local plain = Programs.run(HEAD .. union .. "local u: {integer} = { 1 }\nlocal r = both(1, u)\nprint(r)\n")
  assert(Programs.codes(plain) == "cannot_infer", Programs.codes(plain))
end

-- A generic function passed to an overloaded callee, taken from the values the callee passes it, says which bound a type
-- fails to meet, where it used to be `overload_none`.
-- It is the answer only where it is why the call fails: a function of another arity is rejected as it is, with or without it.
local function test_a_bound_a_passed_generic_function_does_not_meet_is_bound_unmet()
  local head = "local interface Named\n  name: string\nend\nlocal record Plain\n  title: string\nend\n" ..
    "local function label<T is Named>(x: T): string\n  return x.name\nend\nlocal p: Plain = { title = \"ann\" }\n"
  refused(head .. "local ok, r = pcall(label, p)\nprint(ok, r)\n", "bound_unmet")
  -- a bound that is not the only failure is not the answer: declaring `Plain is Named` would still leave this call refused
  refused(head .. "local ok, r = pcall(label, p, 5)\nprint(ok, r)\n", "overload_none")
  -- nor when another argument is refused too: declaring the bound would leave the call refused
  refused(head .. "local function wide(a: integer, b: integer): string\n  return \"\"\nend\nlocal ok, r = xpcall(label, wide, p)\nprint(ok, r)\n",
    "overload_none")
  refused(head .. "local ok, r = xpcall(label, print, p)\nprint(ok, r)\n", "overload_none")
  -- every bound a type fails is named in one message, and an interface can be given the one it lacks
  local two = "local interface Named\n  name: string\nend\nlocal interface Other\n  other: string\nend\n" ..
    "local record Plain\n  title: string\nend\nlocal interface Loose\n  id: string\nend\n" ..
    "local function both<T is Named, U is Other>(a: T, b: U): string\n  return a.name\nend\n" ..
    "local function pair<T is Named, U is Other>(a: T, b: U): string\n  return a.name\nend\n"
  local p, q = "local p: Plain = { title = \"ann\" }\nlocal q: Plain = { title = \"bo\" }\n", ""
  local both = Programs.run(HEAD .. two .. p .. q .. "local ok, r = pcall(both, p, q)\nprint(ok, r)\n")
  local named = both.errors[1]
  assert(Programs.codes(both) == "bound_unmet" and named ~= nil and named.msg:find("`T`", 1, true) ~= nil and
      named.msg:find("`U`", 1, true) ~= nil, Programs.codes(both))
  local loose = Programs.run(HEAD .. two .. "local function use(s: Loose, t: Loose)\n  print(pcall(both, s, t))\nend\nprint(use)\n")
  local on_interface = loose.errors[1]
  assert(on_interface ~= nil and on_interface.fix:find("declare `is Named` on `Loose`", 1, true) ~= nil,
    Programs.codes(loose))
  -- a type the program cannot give the interface to is told only to pass one that has it
  local built_in = Programs.run(HEAD .. head .. "local ok, r = pcall(label, 5)\nprint(ok, r)\n")
  local said = built_in.errors[1]
  assert(Programs.codes(built_in) == "bound_unmet" and said ~= nil and said.fix:find("declare `is", 1, true) == nil and
      said.fix:find("pass a type that declares `is Named`", 1, true) ~= nil, Programs.codes(built_in))
  refused(head .. "local function h(e: any): any\n  return e\nend\nlocal ok, r = xpcall(label, h, p)\nprint(ok, r)\n",
    "bound_unmet")
  stands("local interface Named\n  name: string\nend\nlocal class Person is Named\n  name: string\nend\n" ..
      "local function label<T is Named>(x: T): string\n  return x.name\nend\nlocal p: Person = { name = \"ann\" }\n" ..
      "local ok, r = pcall(label, p)\nprint(ok, r is string)\n", "true\ttrue")
end

-- Every generic function argument whose bound a type fails is waived together when the call is asked again: waiving only
-- the first leaves the second to refuse the call as `overload_none`.
local function test_every_passed_generic_function_with_an_unmet_bound_is_named_once()
  local head = "local interface Named\n  name: string\nend\nlocal record Plain\n  title: string\nend\n" ..
    "local function label<T is Named>(x: T): string\n  return x.name\nend\n" ..
    "local function note<E is Named>(e: E): string\n  return \"n\"\nend\nlocal p: Plain = { title = \"ann\" }\n"
  local both = Programs.run(HEAD .. head .. "local ok, r = xpcall(label, note, p)\nprint(ok, r)\n")
  local first = both.errors[1]
  assert(Programs.codes(both) == "bound_unmet", Programs.codes(both))
  assert(#both.errors == 1 and first ~= nil and first.msg:find("argument 1", 1, true) ~= nil and
      first.msg:find("argument 2", 1, true) ~= nil, Programs.codes(both))
  -- a bound that fails in one argument names that argument alone, whichever it is, and is reported once
  local loose = "local function pass<E>(e: E): string\n  return \"n\"\nend\n"
  local only_first = Programs.run(HEAD .. head .. loose .. "local ok, r = xpcall(label, pass, p)\nprint(ok, r)\n")
  local one = only_first.errors[1]
  assert(Programs.codes(only_first) == "bound_unmet" and #only_first.errors == 1 and one ~= nil and
      one.msg:find("argument 1", 1, true) ~= nil and one.msg:find("argument 2", 1, true) == nil, Programs.codes(only_first))
  local only_second = Programs.run(HEAD .. head .. loose ..
      "local class Person is Named\n  name: string\nend\nlocal q: Person = { name = \"bo\" }\n" ..
      "local ok, r = xpcall(label, note, q)\nprint(ok, r)\n")
  local two = only_second.errors[1]
  assert(Programs.codes(only_second) == "bound_unmet" and #only_second.errors == 1 and two ~= nil and
      two.msg:find("argument 2", 1, true) ~= nil and two.msg:find("argument 1", 1, true) == nil, Programs.codes(only_second))
  -- a literal argument that is wrong on its own is reported beside the bound, each once: the refusal never rests on the
  -- bound alone, and the post-accept check of the literal is not run again for the waived instance
  local literal = Programs.run(HEAD .. head ..
      "local ok, r = xpcall(label, function(e: any): string return 1 end, p)\nprint(ok, r)\n")
  assert(Programs.codes(literal) == "bound_unmet not_assignable" and #literal.errors == 2, Programs.codes(literal))
  -- a call that is refused for another reason too stays `overload_none`, with every bound waived
  refused(head .. "local ok, r = xpcall(label, note, p, 5)\nprint(ok, r)\n", "overload_none")
end

--- Overloads of a declared module `m` to pass generic functions to, for the tests below. A callee with one declaration
--- is not asked again with the waiver, so `y` has a second, of another arity.
local OVERLOADS <const> = "local record m\n" ..
  "  f: function<A, B>((function(A): string), (function(B): string), A, B)\n" ..
  "  f: function<A>((function(A): string), (function(A): string), (function(A): string), A)\n" ..
  "  y: function<A, B, C>((function(A): B), (function(B): C), (function(C): string), A)\n" ..
  "  y: function<A>((function(A): string), A)\n" ..
  "end\nreturn m\n"

local NAMED <const> = "local m = require(\"m\")\nlocal interface Named\n  name: string\nend\n" ..
  "local class Person is Named\n  name: string\nend\nlocal record Plain\n  title: string\nend\n" ..
  "local function label<T is Named>(x: T): string\n  return x.name\nend\n" ..
  "local function note<T is Named>(x: T): string\n  return \"n\"\nend\n" ..
  "local function sname<T is Named>(x: T): string\n  return x.name\nend\n" ..
  "local function ident<T is Named>(x: T): T\n  return x\nend\n" ..
  "local function mk<T is Named>(x: T): Person\n  return { name = x.name }\nend\n" ..
  "local p: Plain = { title = \"ann\" }\n"

local function overloads(call: string): Programs.Run
  return Programs.run(HEAD .. NAMED .. call, nil, { m = OVERLOADS })
end

-- Two overloads that each reach `bound_unmet` with different bounds: the order of the overloads does not say which the
-- call meant, so the call is `overload_none`, as it is without the waiver. Overloads that say alike are one answer.
local function test_two_overloads_that_reach_different_bounds_name_none()
  local r = overloads("m.f(label, note, sname, p)\n")
  assert(Programs.codes(r) == "overload_none" and #r.errors == 1, Programs.codes(r))
end

-- A function whose parameter type is the result of the one before it is found one run after that one is waived, so
-- every run the chain needs is made: stopping after the second misses the third argument.
local function test_a_chain_of_passed_generic_functions_is_waived_to_its_end()
  local chain = overloads("m.y(ident, ident, sname, p)\n")
  local e = chain.errors[1]
  assert(Programs.codes(chain) == "bound_unmet" and #chain.errors == 1 and e ~= nil and e.msg:find("argument 1", 1, true) ~= nil and
      e.msg:find("argument 2", 1, true) ~= nil and e.msg:find("argument 3", 1, true) ~= nil, Programs.codes(chain))
  -- `mk` answers a `Person`, which meets the bound: only the first argument fails it
  local cut = overloads("m.y(mk, ident, sname, p)\n")
  local c = cut.errors[1]
  assert(Programs.codes(cut) == "bound_unmet" and #cut.errors == 1 and c ~= nil and c.msg:find("argument 1", 1, true) ~= nil and
      c.msg:find("argument 2", 1, true) == nil and c.msg:find("argument 3", 1, true) == nil, Programs.codes(cut))
end

-- A bound no declaration can meet is not worded as one to declare: `xpcall`'s handler is given `any`, and a type the
-- callee's declaration fixes cannot be changed by the call.
local function test_a_bound_nothing_can_meet_does_not_say_declare_it()
  local head = "local interface Named\n  name: string\nend\nlocal function note<E is Named>(e: E): string\n  return \"n\"\nend\n"
  local handler = Programs.run(HEAD .. head .. "local ok, r = xpcall(print, note)\nprint(ok, r)\n")
  local h = handler.errors[1]
  assert(Programs.codes(handler) == "bound_unmet" and h ~= nil and h.msg:find("cannot satisfy the bound here", 1, true) ~= nil and
      h.msg:find("does not declare", 1, true) == nil and h.fix:find("declare", 1, true) == nil, h and h.msg or Programs.codes(handler))
  local direct = Programs.run(HEAD .. head .. "local function label<T is Named>(x: T): string\n  return \"\"\nend\nprint(label(1))\n")
  local d = direct.errors[1]
  assert(Programs.codes(direct) == "bound_unmet" and d ~= nil and d.fix:find("declare", 1, true) == nil and
      d.fix:find("pass a type that has the fields of `Named`", 1, true) ~= nil, d and d.fix or Programs.codes(direct))
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
  -- A record that has the interface's field conforms by it, and the field gives the argument.
  assert(type_of(head .. "local record Plain\n  last: integer\nend\nlocal p: Plain = { last = 1 }\nlocal n = latest(p)\n", "n") ==
      "integer")
  refused(head .. "local record Plain\n  first: integer\nend\nlocal p: Plain = { first = 1 }\nlocal n = latest(p)\n",
    "not_assignable")
  -- A record with an array part is a view of that part.
  local rows = "local record Rows is {string}\n  count: integer\nend\nlocal r: Rows = { count = 1, \"a\" }\n"
  assert(type_of(rows .. "local v = first(r)\n", "v") == "string?")
end

-- the built-in bounds `Ordered` and `Numeric` -------------------------------------------------------------------------

local MAX <const> = "local function max<T is Ordered>(a: T, b: T): T\n  if a < b then\n    return b\n  end\n  return a\nend\n"
local SUM <const> = "local function sum<N is Numeric>(xs: {N}, zero: N): N\n  local t = zero\n  for _, x in ipairs(xs) do\n" ..
  "    t = t + x * 2 - 1\n  end\n  return -(-t)\nend\n"

--- A parameter bounded by `Ordered` compares two of its values; a number type, a string type, or a class that declares
--- `__lt` and `__le` meets it, and the call
--- answers the argument's type.
local function test_a_parameter_bounded_by_ordered_compares_its_values()
  stands(MAX .. "print(max(1, 2), max(2.5, 1.5), max(\"a\", \"b\"))\n", "2\t2.5\tb")
  assert(type_of(MAX .. "local s = max(\"a\", \"b\")\n", "s") == "string")
  assert(type_of(MAX .. "local n = max(1, 2)\n", "n") == "integer")
  -- An enum is a string type.
  stands("local enum Size\n  \"small\" \"large\"\nend\n" .. MAX .. "local a: Size = \"small\"\nlocal b: Size = \"large\"\n" ..
      "print(max(a, b))\n", "small")
end

--- `Ordered` is met by no type whose values may be numbers and strings, since `<` of the two raises, nor by a type
--- with no order; a parameter's values compare with no value of another type.
local function test_ordered_refuses_a_type_that_mixes_numbers_and_strings()
  refused(MAX .. "print(max(true, false))\n", "bound_unmet")
  refused(MAX .. "local function g(u: integer | string)\n  print(max(u, u))\nend\ng(1)\n", "bound_unmet")
  refused(MAX .. "local function g(u: integer?)\n  print(max(u, u))\nend\ng(1)\n", "bound_unmet")
  refused("local function f<T is Ordered>(a: T): boolean\n  return a < 1\nend\nprint(f(1))\n", "generic_op")
  refused("local function f<T is Ordered, U is Ordered>(a: T, b: U): boolean\n  return a < b\nend\nprint(f(1, \"a\"))\n",
    "generic_op")
  local r = Programs.run(MAX .. "print(max(true, false))\n")
  local e = Array.at(r.errors, 1)
  assert(e.msg:find("`boolean` is the type parameter `T` of `max`, which is bounded by `Ordered`, and `boolean` is not " ..
      "a type whose values are all numbers or all strings", 1, true) ~= nil, e.msg)
end

--- A parameter bounded by `Numeric` takes arithmetic, which answers its own type with itself or an integer, a number
--- with a float or by `/`; it compares with a number too.
local function test_a_parameter_bounded_by_numeric_takes_arithmetic_of_its_own_type()
  stands(SUM .. "print(sum({ 1, 2 }, 0), sum({ 1.5 }, 0.0))\n", "4\t2.0")
  assert(type_of(SUM .. "local n = sum({ 1, 2 }, 0)\n", "n") == "integer")
  assert(type_of(SUM .. "local n = sum({ 1.5 }, 0.0)\n", "n") == "number")
  stands("local function small<N is Numeric>(x: N): boolean\n  return x < 10 and x >= 0.5\nend\nprint(small(3), small(20.5))\n",
    "true\tfalse")
  refused("local function half<N is Numeric>(x: N): N\n  return x / 2\nend\nprint(half(1))\n", "not_assignable")
  refused("local function scale<N is Numeric>(x: N): N\n  return x * 1.5\nend\nprint(scale(1))\n", "not_assignable")
  refused(SUM .. "print(sum({ \"a\" }, \"b\"))\n", "bound_unmet")
  -- An integer enum is no `Numeric`: the sum of two members is no member.
  refused("local enum Level: integer\n  Low = 1\n  High = 2\nend\n" .. SUM .. "local xs: {Level} = { Level.Low }\n" ..
      "print(sum(xs, Level.Low))\n", "bound_unmet")
end

--- An operator a parameter's bound does not give it is told the bound that does, by the parameter's own name.
local function test_an_operator_on_a_parameter_is_told_the_bound_that_gives_it()
  local r = Programs.run("local function f<Item>(a: Item, b: Item): boolean\n  return a < b\nend\nprint(f(1, 2))\n")
  local e = Array.at(r.errors, 1)
  assert(e.code == "generic_op" and e.fix:find("bound `Item` by `Ordered` where it is declared (`<Item is Ordered>`)", 1, true) ~=
      nil, e.fix)
  local plus = Programs.run("local function f<Item is Ordered>(a: Item): Item\n  return a + a\nend\nprint(f(1))\n")
  local p = Array.at(plus.errors, 1)
  assert(p.msg:find("is bounded by `Ordered` alone", 1, true) ~= nil, p.msg)
  assert(p.fix:find("`<Item is Numeric>`", 1, true) ~= nil, p.fix)
end

--- `Ordered`, `Numeric` and `Key` are bounds and the types of no value.
local function test_a_builtin_bound_is_the_type_of_no_value()
  for _, bound in ipairs({ "Ordered", "Numeric", "Key" }) do
    local r = Programs.run("local x: " .. bound .. " = 1\nprint(x)\n")
    assert(table.concat(r.before, " ") == "bound_as_type", table.concat(r.before, " "))
  end
end

--- A declaration may take the name of a bound, as [`cosmic.key`]'s record does; where it is in scope the name is the declaration's,
--- in a type and after `is` alike.
local function test_a_declaration_named_for_a_bound_takes_the_name_where_it_is_in_scope()
  stands("local record Key\n  x: integer\nend\nlocal k: Key = { x = 1 }\nprint(k.x)\n", "1")
  stands("local interface Ordered\n  rank: integer\nend\nlocal function rank<T is Ordered>(t: T): integer\n  return t.rank\nend\n" ..
      "local record Card\n  rank: integer\nend\nlocal c: Card = { rank = 3 }\nprint(rank(c))\n", "3")
  local r = Programs.run("local record Key\nend\nlocal function f<K is Key>(k: K) print(k) end\n")
  assert(table.concat(r.before, " ") == "bound_not_interface", table.concat(r.before, " "))
end

--- A bound is `Ordered` or `Numeric` only where written as the bound: an alias of one is a type, and refused, wherever
--- the alias is declared.
local function test_an_alias_of_a_builtin_bound_is_refused_even_when_declared_after_its_use()
  local late = Programs.run("local function g<T is A>(a: T) print(a) end\nlocal type A = Ordered\ng(1)\n")
  assert(table.concat(late.before, " "):find("bound_as_type", 1, true) ~= nil, table.concat(late.before, " "))
  local listed = Programs.run("local function g<T is Ordered>(a: T) print(a) end\nlocal type A = {Ordered}\ng(1)\n")
  assert(table.concat(listed.before, " "):find("bound_as_type", 1, true) ~= nil, table.concat(listed.before, " "))
end

--- A `Numeric` value is a `number`, and `math.max` and `math.min` answer the type of their arguments.
local function test_a_numeric_parameter_is_a_number_and_math_max_keeps_its_type()
  stands("local function f<N is Numeric>(a: N, b: N): number\n  local m: N = math.max(a, b)\n  return m\nend\n" ..
      "print(f(1, 2), f(0.5, 0.25))\n", "2\t0.5")
  assert(type_of("local n = math.max(1, 2)\n", "n") == "integer")
  assert(type_of("local n = math.min(1, 2.5)\n", "n") == "number")
  local r = Programs.run("local function f<N is Numeric>(a: N): N\n  return a & 1\nend\nprint(f(1))\n")
  local e = Array.at(r.errors, 1)
  assert(e.msg:find("is bounded by `Numeric`, which takes arithmetic", 1, true) ~= nil, e.msg)
end

--- A generic record bounded by a built-in bound takes the types that meet it.
local function test_a_generic_record_bounded_by_ordered_takes_the_types_that_meet_it()
  stands("local record Range<T is Ordered>\n  low: T\n  high: T\nend\nlocal r: Range<integer> = { low = 1, high = 2 }\n" ..
      "print(r.low < r.high)\n", "true")
  local r = Programs.run("local record Range<T is Ordered>\n  low: T\nend\nlocal r: Range<boolean> = { low = true }\nprint(r)\n")
  assert(table.concat(r.before, " "):find("bound_not_met", 1, true) ~= nil, table.concat(r.before, " "))
end

-- the built-in bound `Key` --------------------------------------------------------------------------------------------

local INDEX <const> = "local function index<K is Key, V>(xs: {V}, key: function(V): K): {K: V}\n" ..
  "  local out: mut {K: V} = {}\n  for _, x in ipairs(xs) do\n    out[key(x)] = x\n  end\n  return out\nend\n"

--- A parameter bounded by `Key` keys a map, and a call passes a type a map may be keyed by.
local function test_a_parameter_bounded_by_key_keys_a_map_and_a_call_passes_a_key_type()
  stands(INDEX .. "local by = index({ \"a\", \"bb\" }, function(s: string): integer return #s end)\nprint(by[2])\n", "bb")
  stands(INDEX .. "local by = index({ 1, 2 }, function(n: integer): boolean return n > 1 end)\nprint(by[true], by[false])\n",
    "2\t1")
  local r = Programs.run(INDEX .. "local by = index({ 1.5 }, function(x: number): number return x end)\nprint(by)\n")
  assert(Programs.codes(r) == "bound_unmet", Programs.codes(r))
  local e = Array.at(r.errors, 1)
  assert(e.msg:find("`number` is the type parameter `K` of `index`, which is bounded by `Key`, and `number` is not " ..
      "`integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata", 1, true) ~= nil, e.msg)
end

--- A type parameter keys a map only where `Key` or an interface bounds it: unbounded, it may be `number`, a union or
--- a function, and the map would take keys no read finds.
local function test_an_unbounded_type_parameter_keys_no_map()
  local r = Programs.run("local function index<K, V>(xs: {V}, key: function(V): K): {K: V}\n  return {}\nend\n")
  assert(table.concat(r.before, " ") == "key_type", table.concat(r.before, " "))
  local e = Array.at(r.lowered.errors, 1)
  assert(e.msg:find("the type parameter `K`, which `Key` does not bound", 1, true) ~= nil, e.msg)
  assert(e.fix:find("bound `K` by `Key` where it is declared (`<K is Key>`)", 1, true) ~= nil, e.fix)
  -- `Ordered` and `Numeric` hold `number`, a float key
  local ordered = Programs.run("local function f<T is Ordered>(m: {T: boolean}) print(m) end\n")
  assert(table.concat(ordered.before, " ") == "key_type", table.concat(ordered.before, " "))
  -- an interface bounds a type parameter by records, classes and interfaces, each a key by identity
  stands("local interface Titled\n  title: string\nend\nlocal record Book\n  title: string\nend\n" ..
      "local function present<N is Titled>(xs: {N}): {N: boolean}\n  local out: mut {N: boolean} = {}\n" ..
      "  for _, x in ipairs(xs) do\n    out[x] = true\n  end\n  return out\nend\n" ..
      "local b: Book = { title = \"b\" }\nprint(present({ b })[b])\n", "true")
end

--- A caller's own type parameter meets `Key` only through its bound, and the fix names where to write it.
local function test_a_callers_type_parameter_passed_to_key_is_bounded_by_it()
  local r = Programs.run("local function set<K is Key>(k: K): {K: boolean}\n  return { [k] = true }\nend\n" ..
      "local function wrap<T>(t: T): integer\n  local _ = set(t)\n  return 1\nend\nprint(wrap(1))\n")
  assert(Programs.codes(r) == "bound_unmet", Programs.codes(r))
  local e = Array.at(r.errors, 1)
  assert(e.msg:find("`T` is not bounded by it", 1, true) ~= nil, e.msg)
  assert(e.fix == "bound `T` by `Key` where it is declared (`<T is Key>`)", e.fix)
  stands("local function set<K is Key>(k: K): {K: boolean}\n  return { [k] = true }\nend\n" ..
      "local function wrap<T is Key>(t: T): boolean\n  return set(t)[t] == true\nend\nprint(wrap(\"a\"))\n", "true")
end

--- A generic record that keys a map by its parameter bounds it by `Key`, and an instance passes a key type.
local function test_a_generic_record_keyed_by_its_parameter_bounds_it_by_key()
  local unbounded = Programs.run("local record Set<K>\n  keys: {K: boolean}\nend\n")
  assert(table.concat(unbounded.before, " ") == "key_type", table.concat(unbounded.before, " "))
  local set = "local record Set<K is Key>\n  keys: {K: boolean}\nend\n"
  stands(set .. "local s: Set<string> = { keys = { [\"a\"] = true } }\nprint(s.keys[\"a\"])\n", "true")
  local float = Programs.run(set .. "local s: Set<number>\n")
  assert(table.concat(float.before, " ") == "float_key", table.concat(float.before, " "))
  local e = Array.at(float.lowered.errors, 1)
  assert(e.msg:find("`Set` bounds its type parameter 1 by `Key`, so `number` would key a map by a float", 1, true) ~= nil, e.msg)
  local union = Programs.run(set .. "local s: Set<string | integer>\n")
  assert(table.concat(union.before, " ") == "key_type", table.concat(union.before, " "))
  -- an optional, a collection or a union of a parameter is no key, whatever the parameter is
  for _, shape in ipairs({ "K?", "{K}", "K | string" }) do
    local open = Programs.run(set .. "local function f<K is Key>(s: Set<" .. shape .. ">) print(s) end\n")
    assert(table.concat(open.before, " ") == "key_type", shape .. ": " .. table.concat(open.before, " "))
  end
  local boxed = Programs.run(set .. "local record Box<T>\n  v: T\nend\nlocal function f<K is Key>(s: Set<Box<K>>) print(s) end\n")
  assert(#boxed.before == 0 and Programs.codes(boxed) == "", table.concat(boxed.before, " ") .. Programs.codes(boxed))
  -- a parameter bounded otherwise is told to take `Key` beside its bound
  local by_ordered = Programs.run(set .. "local function f<K is Ordered>(s: Set<K>) print(s) end\n")
  local o = Array.at(by_ordered.lowered.errors, 1)
  assert(o.code == "bound_not_met" and o.fix == "bound `K` by `Key` where it is declared (`<K is Key & Ordered>`)", o.fix)
  -- a record that passes its parameter on to `Set` bounds it too
  local through = Programs.run(set .. "local record Index<T>\n  set: Set<T>\nend\nlocal i: Index<number>\n")
  assert(table.concat(through.before, " "):find("bound_not_met", 1, true) ~= nil, table.concat(through.before, " "))
end

-- several bounds, `T is A & B` --------------------------------------------------------------------------------------

local SORTED <const> = "local function sorted_set<T is Ordered & Key>(xs: {T}): {T}\n" ..
  "  local seen: mut {T: boolean} = {}\n  local out: mut {T} = {}\n  for _, x in ipairs(xs) do\n" ..
  "    if seen[x] ~= true then\n      seen[x] = true\n      out[#out + 1] = x\n    end\n  end\n" ..
  "  table.sort(out, function(a: T, b: T): boolean return a < b end)\n  return out\nend\n"

--- A parameter with several bounds takes what each gives, a key and `<` here, and a call passes a type that meets
--- every one.
local function test_a_parameter_with_several_bounds_takes_what_each_gives()
  stands(SORTED .. "print(table.concat(sorted_set({ \"b\", \"a\", \"b\" }), \",\"), #sorted_set({ 3, 1, 3 }))\n", "a,b\t2")
  local float = Programs.run(SORTED .. "print(sorted_set({ 1.5 }))\n")
  assert(Programs.codes(float) == "bound_unmet", Programs.codes(float))
  assert(Array.at(float.errors, 1).msg:find("which is bounded by `Key`, and `number` is not", 1, true) ~= nil,
    Array.at(float.errors, 1).msg)
  local flag = Programs.run(SORTED .. "print(sorted_set({ true }))\n")
  assert(Programs.codes(flag) == "bound_unmet", Programs.codes(flag))
  assert(Array.at(flag.errors, 1).msg:find("which is bounded by `Ordered`", 1, true) ~= nil, Array.at(flag.errors, 1).msg)
end

--- What a call is expected to answer does not fix a parameter where it fails the parameter's bounds: the arguments do.
local function test_an_expected_type_that_fails_the_bounds_does_not_fix_the_parameter()
  stands(SORTED .. "local names: {string | integer} = sorted_set({ \"pear\", \"fig\" })\nprint(names[1])\n", "fig")
end

local PERSON <const> = "local interface Titled\n  title: string\nend\nlocal interface Aged\n  age: integer\nend\n" ..
  "local function label<T is Titled & Aged>(t: T): string\n  return t.title .. \" \" .. tostring(t.age)\nend\n"

--- A parameter bounded by two interfaces has the fields of both, and a type argument has every field of each.
local function test_a_parameter_bounded_by_two_interfaces_has_the_fields_of_both()
  stands(PERSON .. "local record Book\n  title: string\n  age: integer\nend\nlocal b: Book = { title = \"b\", age = 3 }\n" ..
      "print(label(b))\n", "b 3")
  local short = Programs.run(PERSON .. "local record Note\n  title: string\nend\nlocal n: Note = { title = \"n\" }\n" ..
      "print(label(n))\n")
  assert(Programs.codes(short) == "bound_unmet", Programs.codes(short))
  assert(Array.at(short.errors, 1).msg:find("has no field `age: integer`", 1, true) ~= nil, Array.at(short.errors, 1).msg)
  local missing = Programs.run(PERSON .. "local function g<T is Titled & Aged>(t: T): string\n  return t.name\nend\n")
  local e = Array.at(missing.errors, 1)
  assert(e.code == "not_indexable" and e.msg:find("none of its bounds, `Aged & Titled`, declares it", 1, true) ~= nil, e.msg)
end

--- The bounds of a parameter are a set: their order and a repeat change no type, and the type shows them in one order.
local function test_the_bounds_of_a_parameter_are_a_set()
  local both = PERSON .. "local h: function<T is Aged & Titled & Aged>(T): string = label\nlocal _ = h\nprint(\"same\")\n"
  stands(both, "same")
  assert(type_of(PERSON, "label") == "function<T is Aged & Titled>(T): string", type_of(PERSON, "label"))
end

--- A record bounded by several bounds holds its arguments to each, and a type parameter passed on to it has them all.
local function test_a_record_with_several_bounds_holds_a_parameter_passed_on_to_each()
  local set = "local record Sorted<K is Ordered & Key>\n  keys: {K: boolean}\n  low: K\nend\n"
  stands(set .. "local s: Sorted<string> = { keys = {}, low = \"a\" }\nprint(s.low < \"b\")\n", "true")
  local only_key = Programs.run(set .. "local function f<K is Key>(s: Sorted<K>) print(s) end\n")
  local e = Array.at(only_key.lowered.errors, 1)
  assert(e.code == "bound_not_met" and e.fix == "bound `K` by `Ordered` where it is declared (`<K is Key & Ordered>`)", e.fix)
  local both = Programs.run(set .. "local function f<K is Key & Ordered>(s: Sorted<K>) print(s) end\n")
  assert(#both.before == 0, table.concat(both.before, " "))
end

--- A parameter bounded by two interfaces is below an interface whose fields they have together, and one passed on to a
--- parameter bounded by more is told the bounds to write.
local function test_a_parameter_with_two_interface_bounds_meets_an_interface_of_their_fields()
  local both = PERSON .. "local interface Card\n  title: string\n  age: integer\nend\n" ..
    "local function show_card<C is Card>(c: C): string\n  return c.title\nend\n" ..
    "local function pass<T is Titled & Aged>(t: T): string\n  return show_card(t)\nend\n"
  stands(both .. "local record Book\n  title: string\n  age: integer\nend\nlocal b: Book = { title = \"b\", age = 1 }\n" ..
      "print(pass(b))\n", "b")
  local one = Programs.run(PERSON .. "local function pass<T is Titled>(t: T): string\n  return label(t)\nend\n")
  local e = Array.at(one.errors, 1)
  assert(e.code == "bound_unmet" and e.fix == "bound `T` by `Aged` where it is declared (`<T is Aged & Titled>`)", e.fix)
end

local SOME_HEAD <const> = "local function first<T is Some>(xs: {T}): (T) | (nil, string)\n" ..
  "  local x = xs[1]\n  if x == nil then\n    return nil, \"empty\"\n  end\n  return x\nend\n" ..
  "local function wrap<T is Some>(x: T): T\n  return x\nend\n"

--- A type parameter bounded by `Some` takes only types that are never nil, so a value of it tells one list of a call
--- from another that has `nil` there; any other bound does too, since none holds `nil`.
local function test_a_type_parameter_bounded_by_some_is_never_nil()
  Programs.stands(SOME_HEAD .. "local v, why = first({ 3 })\nif v == nil then\n  error(why)\nend\n" ..
      "local w, _ = first({ { \"a\" } })\nprint(v + 1, w ~= nil, wrap(\"s\"))\n", "4\ttrue\ts")
  -- A closed source answers `false`, not a failure, beside its values.
  Programs.stands("local function next_of<T is Some>(xs: {T}, i: integer): (T | false) | (nil, string)\n" ..
      "  local x = xs[i]\n  if x == nil then\n    return false\n  end\n  return x\nend\n" ..
      "local x, _ = next_of({ 7 }, 1)\nlocal y, _ = next_of({ 7 }, 2)\nprint(x, y)\n", "7\tfalse")
  -- A generic body tells the lists apart by its own bounded type parameter.
  Programs.stands(SOME_HEAD .. "local function both<U is Some>(xs: {U}): (U) | (nil, string)\n" ..
      "  local v, why = first(xs)\n  if v == nil then\n    return nil, why\n  end\n  return v\nend\n" ..
      "local a, _ = both({ 1 })\nlocal none: {string} = {}\nlocal b, why = both(none)\nprint(a, b, why)\n", "1\tnil\tempty")
  Programs.stands("local function key_of<K is Key>(k: K): (K) | (nil, string)\n  return k\nend\n" ..
      "local k, _ = key_of(\"a\")\nprint(k)\n", "a")
  -- A method of a bounded generic record is defined with the record's bound.
  Programs.stands("local record Box<T is Some>\n  v: T\n  get: function(self: Box<T>): (T) | (nil, string)\nend\n" ..
      "function Box.get<T is Some>(self: Box<T>): (T) | (nil, string)\n  return self.v\nend\n" ..
      "local function boxed<T is Some>(v: T): Box<T>\n  local b: Box<T> = { v = v, get = Box.get }\n  return b\nend\n" ..
      "local v, _ = boxed(3):get()\nprint(v)\n", "3")
  -- A type that may be nil meets no `Some`, nor does a type parameter with no bound.
  Programs.refused(SOME_HEAD .. "local function f(m: integer?)\n  print(wrap(m))\nend\n", "bound_unmet")
  local passed = Programs.run(SOME_HEAD .. "local function pass<U>(u: U): U\n  return wrap(u)\nend\n")
  local e = Array.at(passed.errors, 1)
  assert(e.code == "bound_unmet" and e.fix == "bound `U` by `Some` where it is declared (`<U is Some>`)", e.fix)
end

--- A test against `false` drops `false` where it fails: `T | false` is `T` there, so "none" as a value is taken apart
--- without `is`, which a type parameter has no tag for.
local function test_a_test_against_false_drops_false_where_it_fails()
  Programs.stands("local function f(x: integer | false): integer\n  if x == false then\n    return 0\n  end\n  return x + 1\nend\n" ..
      "local function g<T is Some>(x: T | false, d: T): T\n  if x == false then\n    return d\n  end\n  return x\nend\n" ..
      "local function h(x: string | false): string\n  if false ~= x then\n    return x\n  end\n  return \"none\"\nend\n" ..
      "print(f(1), f(false), g(3, 0), g(false, 9), h(\"a\"), h(false))\n", "2\t0\t3\t9\ta\tnone")
  -- A test against `true` drops `true` the same way, and nil stays.
  Programs.stands("local function g(b: boolean?): string\n  if b ~= true then\n    local x: false? = b\n    return tostring(x)\n" ..
      "  end\n  return \"t\"\nend\nprint(g(true), g(false), g(nil))\n", "t\tfalse\tnil")
  -- Where it holds, the value is not narrowed to `false`: only nil is ruled out.
  Programs.refused("local function f(x: integer | false): integer\n  if x == false then\n    return x\n  end\n  return 0\nend\n",
    "not_assignable")
end

local function test_a_generic_function_in_a_field_that_may_be_nil_is_narrowed_and_called()
  local head = "local record R\n  pick?: function<T>(T): T\nend\nlocal function same<T>(x: T): T\n  return x\nend\n"
  Programs.stands(head .. "local r: R = { pick = same }\nlocal p = r.pick\nif p ~= nil then\n" ..
      "  print(p(3) + 1, p(\"a\") .. \"b\")\nend\n", "4\tab")
  Programs.stands(head .. "local r: R = { pick = same }\nif r.pick ~= nil then\n  print(r.pick(2) * 2)\nend\n", "4")
  Programs.stands(head .. "local r: R = { pick = same }\nassert(r.pick)\nprint(r.pick(1), r.pick(\"x\"))\n", "1\tx")
  -- A method-style field, and a type parameter an optional field holds, filled with a generic function.
  Programs.stands("local record M\n  pick?: function<T>(self: M, T): T\nend\nlocal function own<T>(_: M, x: T): T\n" ..
      "  return x\nend\nlocal m: M = { pick = own }\nif m.pick ~= nil then\n  print(m:pick(5), m:pick(\"s\"))\nend\n", "5\ts")
  Programs.stands("local record Box<X>\n  v?: X\nend\nlocal function same<T>(x: T): T\n  return x\nend\n" ..
      "local b: Box<function<T>(T): T> = { v = same }\nlocal v = b.v\nif v ~= nil then\n  print(v(7))\nend\n", "7")
  -- Until it is narrowed, it may be nil.
  Programs.refused(head .. "local r: R = { pick = nil }\nprint(r.pick(1))\n", "nil_not_allowed")
end

local function test_a_generic_function_whose_result_nothing_solves_is_no_function_of_a_fixed_result()
  -- `trust` answers a real value of `T` through its cast, so `T` is no `never` that would drop
  -- the result alternatives of the type wanted.
  local trust = "local function trust<T>(v: any): T\n  return v as T -- checked: cast_refused\nend\n"
  Programs.refused(trust .. "local function use(f: function(any): (true, string) | (false, string)): string\n" ..
      "  local ok, s = f(42)\n  if ok then return s:upper() end\n  return s\nend\nprint(use(trust))\n", "cast_refused not_assignable")
  Programs.refused("local function pair<T>(v: any): (integer, T)\n  return 1, v as T -- checked: cast_refused\nend\n" ..
      "local f: function(any): string = pair\nprint(f(1))\n", "cast_refused not_assignable")
end
