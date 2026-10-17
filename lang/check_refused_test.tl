--- The programs the fork accepts and the plan refuses, as questions of expressions: the pinned holes of
--- [`build/teal_test.tl`], translated into the grammar. The comment of each test names the test of that file that
--- pins the hole, and each program is refused with the code of the rule that closes it. A hole that is a relation
--- question is [`lang.relation_refused_test`]'s, one of flow (a narrowing the fork loses at a join, a function that
--- reaches its end) waits for the flow piece, and the metatables are the class piece's.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

--- Checks that `source` has exactly the errors `codes` (space separated), and that the first says `msg`.
local function refused(source: string, codes: string, msg?: string)
  local r = Programs.run(source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" ..
      (r.errors[1] ~= nil and r.errors[1].msg or ""))
  if msg ~= nil then
    assert(r.errors[1].msg:find(msg, 1, true) ~= nil, r.errors[1].msg .. "\nwanted " .. msg)
  end
end

--- Checks that `source` has no error.
local function accepted(source: string)
  local r = Programs.run(source)
  assert(#r.before == 0 and #r.errors == 0, table.concat(r.before, " ") .. (r.errors[1] ~= nil and r.errors[1].msg or "") ..
      " in\n" .. source)
end

-- `test_as_and_is_forge_a_never_function`: a cast makes a function that returns a never function, and `is` on
-- untrusted data or on a record tests what no tag says.
local function test_a_cast_and_a_test_of_a_function_type_or_a_record_forge_nothing()
  refused("local v = print as function(): never\n", "cast_refused", "`as` is not in the language")
  local records = "local record P\n  die: function(): never\nend\nlocal record Q\n  die: function()\nend\n"
  refused(records .. "local function f(q: Q): P\n  local p: P = q as P\n  return p\nend\n", "cast_refused")
  refused("local function f(v: any): integer\n  if v is function(): never then\n  end\n  return 1\nend\n", "is_on_record",
    "a function type is tested as `function`")
  refused(records .. "local function f(v: any): integer\n  if v is P then\n  end\n  return 1\nend\n", "is_on_record",
    "a record leaves nothing to test")
end

-- `test_an_untyped_value_is_told_the_check_and_the_cast`: untrusted data is read and stored by no program, and the
-- error gives the validator.
local function test_untrusted_data_is_neither_read_nor_assigned_to_a_type()
  local decoded = "local decode: function(string): any, string\n"
  refused(decoded .. "local cfg = decode(\"\")\nlocal x = cfg.cmd\n", "any_use", "`cfg` is untrusted data (`any`)")
  refused(decoded .. "local n: integer = decode(\"\")\n", "any_use", "`decode(\"\")` is untrusted data (`any`)")
  refused("local record Spec\n  cmd: string\nend\nlocal function run(s: Spec)\nend\nlocal function f(c: any)\n  run(c)\nend\n",
    "any_use")
  refused("local function f(a: any)\n  print(a .. \"x\", a + 1, a < 2, -a)\nend\n", "any_use any_use any_use any_use")
end

-- `test_a_literal_nil_is_refused_for_a_parameter_that_does_not_take_it` and
-- `test_an_argument_that_may_be_nil_is_refused_for_any_parameter`: nil is given only where it is declared taken,
-- whatever the callee: a function, a method, a function field, a rest parameter.
local function test_a_value_that_may_be_nil_is_no_argument_for_a_parameter_that_does_not_take_it()
  local head = "local function find(): string?\n  return nil\nend\nlocal s = find()\n" ..
    "local function greet(name: string): string\n  return name\nend\n"
  refused(head .. "local x = greet(nil)\n", "nil_not_allowed", "nil is given as argument 1 of `greet`")
  refused(head .. "local x = greet(s)\n", "nil_not_allowed", "`s` is `string?`, so it may be nil, where `string` is wanted as argument 1 of `greet`")
  refused(head .. "local function put(n: integer, name: string)\nend\nput(1, s)\n", "nil_not_allowed")
  local method = head .. "local record Box\n  put: function(Box, string)\nend\nlocal box: Box = { put = function(_b: Box, _n: string) end }\n"
  refused(method .. "box:put(s)\n", "nil_not_allowed", "as argument 1 of `box:put`")
  refused(method .. "box.put(box, s)\n", "nil_not_allowed", "as argument 2 of `box.put`")
  refused(head .. "local function all(...: string): integer\n  return 0\nend\nlocal n = all(\"a\", s)\n", "nil_not_allowed",
    "as argument 2 of `all`")
  accepted(head .. "local function opt(name?: string)\nend\nopt(s)\nopt(nil)\nopt()\n")
  accepted(head .. "local function open(name: string?)\nend\nopen(s)\nopen(nil)\n")
  accepted(head .. "local function open(name: any)\nend\nopen(s)\nopen(nil)\n")
end

-- `test_an_operand_that_may_be_nil_is_refused` and `test_a_conjunction_with_a_nil_left_operand_may_be_nil`: no
-- operator takes an optional, and `x and y` answers its left operand when that is nil.
local function test_a_value_that_may_be_nil_is_no_operand()
  local head = "local record R\n  name?: string\n  n?: integer\n  items?: {string}\nend\nlocal r: R = {}\n" ..
    "local function find(): string?\n  return nil\nend\nlocal s = find()\n"
  local uses: {string} = {
    "s .. \"x\"", "\"x\" .. s", "r.name .. \"x\"", "#s", "#r.items", "-r.n", "~r.n", "r.n + 1", "1 + r.n", "r.n // 2",
    "r.n % 2", "r.n ^ 2", "r.n & 1", "r.n << 1", "r.n < 3", "3 <= r.n", "r.name < \"a\"", "s .. s",
  }
  for _, use in ipairs(uses) do
    local r = Programs.run(head .. "local v = " .. use .. "\n")
    assert(#r.before == 0 and #r.errors >= 1 and r.errors[1].code == "nil_not_allowed", use .. ": " .. Programs.codes(r))
  end
  local ands = head .. "local z: string = \"z\"\nlocal x = find()\n"
  refused(ands .. "local v = (x and x) .. \"a\"\n", "nil_not_allowed", "`(x and x)` is `string?`")
  refused(ands .. "local v = \"a\" .. (x and z)\n", "nil_not_allowed")
  refused(ands .. "local v = #(x and z)\n", "nil_not_allowed")
  accepted(ands .. "local v = (x or z) .. \"a\"\nlocal w = #(r.items or {})\n")
end

-- [`test_a_numeric_for_bound_that_may_be_nil_is_refused`].
local function test_a_numeric_for_bound_that_may_be_nil_is_refused()
  local head = "local function count(): number?\n  return nil\nend\nlocal n = count()\n"
  refused(head .. "for i = 1, n do\nend\n", "nil_not_allowed", "`n` is `number?`, so it may be nil, and `for limit` takes numbers")
  refused(head .. "for i = n, 3 do\nend\n", "nil_not_allowed", "`for start`")
  refused(head .. "for i = 1, 3, n do\nend\n", "nil_not_allowed", "`for step`")
  accepted(head .. "for i = 1, n or 0 do\nend\n")
end

-- `test_a_literal_omitting_a_required_field_is_refused` and `test_a_nested_literal_and_an_interface_are_checked`: a
-- literal gives every field of its record that is not omittable, to any depth, and an interface is made by a class.
local function test_a_literal_gives_every_field_its_record_needs()
  local person = "local record Person\n  name: string\n  age: integer\n  nick?: string\nend\n"
  refused(person .. "local p: Person = {}\n", "literal_missing", "this literal of `Person` leaves out `name` and `age`")
  refused(person .. "local p: Person = { age = 3 }\n", "literal_missing", "leaves out `name`")
  refused(person .. "local function f(p: Person)\nend\nf({ name = \"a\" })\n", "literal_missing", "leaves out `age`")
  accepted(person .. "local p: Person = { name = \"a\", age = 3 }\n")
  local nested = "local record Inner\n  x: integer\n  y?: integer\nend\nlocal record Outer\n  inner: Inner\n  tag?: string\nend\n"
  refused(nested .. "local o: Outer = { inner = {} }\n", "literal_missing", "this literal of `Inner` leaves out `x`")
  refused(nested .. "local o: Outer = {}\n", "literal_missing", "this literal of `Outer` leaves out `inner`")
  accepted(nested .. "local o: Outer = { inner = { x = 1 } }\n")
  refused("local interface Named\n  name: string\nend\nlocal n: Named = { name = \"a\" }\n", "literal_shape",
    "a table literal cannot make `Named`, an interface")
  refused("local record Box<T>\n  value: T\n  note?: string\nend\nlocal b: Box<string> = {}\n", "literal_missing", "leaves out `value`")
  accepted("local record Box<T>\n  value: T\n  note?: string\nend\nlocal b: Box<string> = { value = \"a\" }\n")
end

-- `test_a_literal_takes_never_from_its_context`: a function literal takes its returns from the position, a `never`
-- one included, and so cannot return.
local function test_a_function_literal_in_a_position_that_never_returns_cannot_return()
  local seam = "local record Seam\n  exit: function(status?: integer): never\nend\n"
  refused(seam .. "local s: Seam = { exit = function(_) return end }\n", "return_unexpected",
    "this function is declared `never` and cannot return")
  accepted(seam .. "local s: Seam = { exit = function(_) error(\"exit\") end }\n")
  local plain = "local record Seam\n  exit: function(status?: integer)\nend\n"
  accepted(plain .. "local s: Seam = { exit = function(_) print(\"x\") end }\n")
end

-- `test_a_never_function_neither_returns_nor_reaches_its_end`: a function declared `never` returns nothing.
local function test_a_never_function_has_no_return()
  refused("local function f(): never\n  return 1\nend\n", "return_unexpected")
  refused("local function f(m: string): never\n  if m == \"\" then\n    return\n  end\n  error(m)\nend\n", "return_unexpected")
  accepted("local function f(m: string): never\n  error(m)\nend\n")
end

-- `test_an_optional_field_admits_nil` and `test_an_optional_field_in_nested_and_generic_records`: an optional field
-- is read as optional and written as its type; its methods and fields are read after a test, and the test is flow's.
local function test_an_optional_field_is_read_as_optional_and_written_as_its_type()
  local declared = "local record R\n  mut name?: string\nend\nlocal r: R = {}\n"
  accepted(declared .. "r.name = nil\nr.name = \"x\"\n")
  refused(declared .. "local u = r.name:upper()\n", "nil_not_allowed", "`r.name` is `string?`, so it may be nil")
  refused(declared .. "r.name = 1\n", "not_assignable")
  accepted(declared .. "local n: string = r.name or \"none\"\n")
  local nested = "local record Outer\n  record Inner\n    depth?: integer\n  end\n  inner?: Inner\nend\nlocal o: Outer = {}\n"
  refused(nested .. "local d = o.inner.depth\n", "nil_not_allowed")
  local callback = "local record R\n  done?: function(code: integer)\nend\nlocal r: R = {}\n"
  refused(callback .. "r.done(1)\n", "nil_not_allowed", "`r.done` is `(function(integer))?`, so it may be nil, and it is called")
end

-- `test_rawset_refuses_a_record`: `rawset` is generic, so the call is not yet checked and says so; a record is
-- no map in the relation, so the call is refused once the generics piece types it.
local function test_a_generic_call_that_takes_a_record_for_a_map_is_reported_not_accepted()
  local r = Programs.run("local record R\n  name: string\nend\nlocal r: R = { name = \"a\" }\n" ..
      "local function rawset<K, V>(m: {K: V}, k: K, v: V)\nend\nrawset(r, \"name\", 1)\n")
  assert(#r.before == 0 and Programs.codes(r) == "unchecked_generic", Programs.codes(r))
end

-- `test_a_wrong_call_through_a_typed_variable_is_refused`: a callee's parameters hold wherever the function came
-- from: an alias, a function in a literal, a field.
local function test_a_function_is_called_with_its_parameters_wherever_it_came_from()
  local head = "local function greet(name: string): string\n  return name\nend\nlocal alias = greet\n"
  refused(head .. "local a = alias(1)\n", "not_assignable", "`1` is `integer`, where `string` is wanted as argument 1 of `alias`")
  refused("local record Bag\n  insert: function({string}, string)\nend\n" ..
      "local bag: Bag = { insert = function(_l: {string}, _v: string) end }\nbag.insert({}, 1)\n", "not_assignable")
  refused("local function f(a: integer)\nend\nf(\"x\")\nf(1, 2)\nf()\n", "not_assignable arity arity")
end
