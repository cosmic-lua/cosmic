--- The class piece of the new checker ([`lang.check`], [`lang.declarations`]): classes are nominal, a value of one is
--- made by a table literal typed as it, a class's names are distinct and its `__close` and `__tostring` are held to
--- what Lua calls, a `<close>` local holds one with a `__close`, and `is` of one is the test of its metatable. A
--- declaration used as a value is a type of its own. The code generator's side is [`lang.codegen_test`]'s.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{ cpu_features = true, grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

--- Checks that `source` has exactly the errors `codes` (space separated) after the declarations, and that the first
--- says `msg`.
local function refused(source: string, codes: string, msg?: string, modules?: {string: string}, declared?: {string: string})
  local r = Programs.run(source, modules, declared)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" ..
      (r.errors[1] ~= nil and r.errors[1].msg or ""))
  if msg ~= nil then
    assert(r.errors[1].msg:find(msg, 1, true) ~= nil, r.errors[1].msg .. "\nwanted " .. msg)
  end
end

--- Checks that `source` has no error.
local function accepted(source: string, modules?: {string: string}, declared?: {string: string})
  local r = Programs.run(source, modules, declared)
  assert(#r.before == 0 and #r.errors == 0, table.concat(r.before, " ") .. (r.errors[1] ~= nil and r.errors[1].msg or "") ..
      " in\n" .. source)
end

--- Checks that the declarations of `source` have exactly the errors `codes`, and that the first says `msg`.
local function declared_wrong(source: string, codes: string, msg: string)
  local r = Programs.run(source)
  local got: mut {string} = {}
  for _, e in ipairs(r.lowered.errors) do
    got[#got + 1] = e.code
  end
  assert(table.concat(got, " ") == codes, table.concat(got, " ") .. " in\n" .. source)
  local found = false
  for _, e in ipairs(r.lowered.errors) do
    found = found or e.msg:find(msg, 1, true) ~= nil
  end
  assert(found, "no error says " .. msg .. " in\n" .. source)
end

local COUNTER <const> = "local class Counter\n  mut n: integer\n  function bump(self, by: integer): integer\n" ..
  "    self.n = self.n + by\n    return self.n\n  end\nend\n"

-- nominal ---------------------------------------------------------------------------------------------------

local function test_two_classes_of_one_shape_are_two_types()
  local twins = "local class A\n  n: integer\nend\nlocal class B\n  n: integer\nend\nlocal a: A = { n = 1 }\n"
  refused(twins .. "local b: B = a\n", "not_assignable", "`a` is `A`, where `B` is wanted")
  refused(twins .. "local function take(b: B)\nend\ntake(a)\n", "not_assignable")
  accepted(twins .. "local again: A = a\n")
end

local function test_a_class_and_a_record_of_one_shape_are_two_types()
  local pair = "local class C\n  n: integer\nend\nlocal record R\n  n: integer\nend\n"
  refused(pair .. "local c: C = { n = 1 }\nlocal r: R = c\n", "not_assignable", "where `R` is wanted")
  refused(pair .. "local r: R = { n = 1 }\nlocal c: C = r\n", "not_assignable", "where `C` is wanted")
end

local function test_a_class_is_below_the_interfaces_it_lists_and_no_other()
  local head = "local interface Sized\n  size: function(self: Sized): integer\nend\n" ..
    "local interface Other\n  size: function(self: Other): integer\nend\n" ..
    "local class Bag is Sized\n  function size(self): integer\n    return 1\n  end\nend\n"
  accepted(head .. "local b: Bag = {}\nlocal s: Sized = b\n")
  refused(head .. "local b: Bag = {}\nlocal o: Other = b\n", "not_assignable", "`b` is `Bag`, where `Other` is wanted")
  local r = Programs.run(head .. "local b: Bag = {}\nlocal o: Other = b\n")
  assert(r.errors[1].fix:find("list the interface in the declaration of `Bag` with `is Other`", 1, true) ~= nil, r.errors[1].fix)
end

-- a value is made by a literal -------------------------------------------------------------------------------

local function test_a_literal_of_a_class_names_every_field_a_field_not_yet_known_by_its_empty_value()
  local head = "local class Handle\n  fd: integer\n  name?: string\n  mut tries: integer\nend\n"
  refused(head .. "local h: Handle = { fd = -1, tries = 0 }\n", "literal_missing", "this literal of `Handle` leaves out `name`")
  refused(head .. "local h: Handle = {}\n", "literal_missing", "leaves out `fd`, `name` and `tries`")
  accepted(head .. "local h: Handle = { fd = -1, name = nil, tries = 0 }\n")
  accepted(head .. "local h: Handle = { fd = -1, name = \"x\", tries = 0 }\n")
  local r = Programs.run(head .. "local h: Handle = { fd = 1 }\n")
  assert(r.errors[1].fix:find("a class literal names every field", 1, true) ~= nil, r.errors[1].fix)
  assert(r.errors[1].fix:find("a `?` field as `name = nil`", 1, true) ~= nil, r.errors[1].fix)
  -- A record leaves a `?` field out.
  accepted("local record Plain\n  fd: integer\n  name?: string\nend\nlocal p: Plain = { fd = 1 }\n")
end

local function test_the_literals_that_make_a_class_are_the_ones_the_checker_reports_to_the_generator()
  local r = Programs.run(COUNTER .. "local record Plain\n  n: integer\nend\n" ..
      "local c: Counter = { n = 0 }\nlocal p: Plain = { n = 0 }\nlocal d: Counter = { n = 1 }\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  local classes: mut {string} = {}
  for _, decl in pairs(r.result.literals) do
    classes[#classes + 1] = decl.name
  end
  assert(table.concat(classes, " ") == "Counter Counter", table.concat(classes, " "))
end

local function test_a_class_value_is_made_by_nothing_but_a_literal_typed_as_the_class()
  -- the declaration is the table of its functions, no value of it
  refused(COUNTER .. "local c: Counter = Counter\n", "declaration_value", "`Counter` is `Counter (declaration)`, the table of " ..
      "the functions of `Counter`, where a value of `Counter` is wanted")
  refused(COUNTER .. "local function take(c: Counter)\nend\ntake(Counter)\n", "declaration_value")
  -- a cast and a call of `setmetatable` make none
  refused(COUNTER .. "local record Plain\n  n: integer\nend\nlocal p: Plain = { n = 0 }\nlocal c: Counter = p as Counter\n",
    "cast_refused")
  refused(COUNTER .. "local c = setmetatable({ n = 0 }, Counter)\n", "setmetatable_call", "a program has no `setmetatable`")
  -- a literal without the class to make it from is no class value
  refused(COUNTER .. "local t = { n = 0 }\nlocal c: Counter = t\n", "record_as_map")
  -- a literal is the class only where it is checked against it
  refused(COUNTER .. "local interface Bumper\n  n: integer\nend\nlocal b: Bumper = { n = 0 }\n", "literal_shape")
  accepted(COUNTER .. "local c: Counter = { n = 0 }\nlocal d: Counter? = { n = 1 }\n" ..
      "local function make(): Counter\n  return { n = 2 }\nend\n")
end

local function test_a_class_of_another_module_is_made_there_by_a_function_and_not_by_a_literal_here()
  local modules: {string: string} = { other = "local class K\n  n: integer\n  function get(self): integer\n    return self.n\n  end\nend\n" ..
      "function K.make(): K\n  return { n = 1 }\nend\nreturn K\n" }
  local head = "local type K = require(\"other\")\nlocal K_module = require(\"other\")\n"
  refused(head .. "local k: K = { n = 1 }\n", "class_scope", "a class of the module `other`, whose metatable only that module reaches",
    modules)
  accepted(head .. "local k: K = K_module.make()\nlocal n: integer = k:get()\n", modules)
  local r = Programs.run(head .. "local k: K = { n = 1 }\n", modules)
  assert(next(r.result.literals) == nil, "a literal of a class out of reach is not reported to the generator")
end

local function test_a_class_declared_inside_another_type_has_no_table_to_make_or_test_its_values_with()
  local head = "local record Outer\n  class Inner\n    n: integer\n  end\nend\n"
  refused(head .. "local i: Outer.Inner = { n = 1 }\n", "class_scope",
    "this literal makes a value of `Outer.Inner`, a class declared inside `Outer`, which has no table of its own at run time")
  refused(head .. "local function f(v: any): boolean\n  return v is Outer.Inner\nend\n", "class_scope",
    "tests the metatable of a class declared inside `Outer`")
  local r = Programs.run(head .. "local i: Outer.Inner = { n = 1 }\n")
  assert(r.errors[1].fix == "declare `Outer.Inner` beside the type around it, as a statement of the module", r.errors[1].fix)
  local module = Programs.run("local class Cell\n  n: integer\nend\nlocal c: Cell = { n = 1 }\n")
  assert(#module.errors == 0)
end

local function test_a_literal_or_a_test_of_a_class_before_its_declaration_reads_a_table_that_is_not_made_yet()
  local later = "local class B\n  m: integer\nend\n"
  refused("local function make(): B\n  return { m = 1 }\nend\n" .. later, "class_scope",
    "this literal makes a value of `B`, a class declared further down the module, whose table is not made yet")
  refused("local class A\n  function mk(self): B\n    return { m = 1 }\n  end\nend\n" .. later, "class_scope",
    "a class declared further down the module")
  local r = Programs.run("local function make(): B\n  return { m = 1 }\nend\n" .. later)
  assert(r.errors[1].fix:find("move the declaration of `B` above this", 1, true) ~= nil, r.errors[1].fix)
  assert(next(r.result.literals) == nil, "a literal before its class is not reported to the generator")
  -- after the declaration, in a function or in a method of the class itself, it is fine
  accepted(later .. "local function make(): B\n  return { m = 1 }\nend\n")
  accepted("local class C\n  m: integer\n  function again(self): C\n    return { m = self.m }\n  end\nend\n")
end

local function test_a_class_declared_in_a_block_has_a_table_for_each_run_so_no_literal_or_test_reaches_it()
  local head = "local function f(): integer\n  local class B\n    m: integer\n  end\n"
  refused(head .. "  local b: B = { m = 1 }\n  return b.m\nend\n", "class_scope",
    "a class declared in a block, whose table is made again each time the block runs")
  refused(head .. "  local function g(v: any): boolean\n    return v is B\n  end\n  return 1\nend\n", "class_scope",
    "tests the metatable of a class declared in a block")
  local r = Programs.run(head .. "  local b: B = { m = 1 }\n  return b.m\nend\n")
  assert(r.errors[1].fix == "declare `B` at the top level of the module, as a statement of it", r.errors[1].fix)
end

local function test_the_table_of_a_class_has_its_methods_and_functions_and_none_of_the_fields_of_its_values()
  local head = "local class K\n  s?: string\n  mut n: integer\n  function m(self): integer\n    return 1\n  end\nend\n" ..
    "function K.make(): K\n  return { s = nil, n = 1 }\nend\n"
  -- a write to a field would set what every value that lacks it reads
  refused(head .. "K.s = \"x\"\n", "field_unknown", "`K` has no field `s`")
  refused(head .. "K.n = 2\n", "field_unknown", "`K` has no field `n`")
  refused(head .. "local n: integer = K.n\n", "field_unknown", "`K` has no field `n`")
  -- a metamethod can neither be read from it nor set on it
  refused("local class P\n  n: integer\nend\nP.__gc = 1\n", "field_unknown", "`P` has no field `__gc`")
  -- its methods are read, as functions of the value first, and not assigned; its functions are called and not assigned
  accepted(head .. "local f = K.m\nlocal made: K = K.make()\nlocal one: integer = K.m(made)\n")
  refused(head .. "local f = K.m\nK.m = f\n", "field_unknown", "`K` has no field `m`")
  refused(head .. "local g = K.make\nK.make = g\n", "field_fixed", "`K.make` is fixed")
  -- an instance still has its fields, and writes its `mut` ones
  accepted(head .. "local k: K = K.make()\nk.n = 3\nlocal s: string? = k.s\n")
end

local function test_the_error_for_a_module_typed_with_its_record_says_what_to_write_instead()
  local record = "local record Circle\n  radius: number\nend\nfunction Circle.unit(): Circle\n  return { radius = 1.0 }\nend\n"
  local r = Programs.run(record .. "local c: Circle = Circle\n")
  assert(Programs.codes(r) == "declaration_value", Programs.codes(r))
  -- a project has no ceilings file, and the checker's TODO is no advice to its author: the fix says what to write
  local told = assert(r.errors[1]).fix
  assert(told:find("ceilings", 1, true) == nil and told:find("TODO", 1, true) == nil, told)
  assert(told:find("call a function on the module (`Circle.f(...)`) or pass the function itself", 1, true) ~= nil, told)
  local field = Programs.run(record .. "local record Holder\n  circle: Circle\nend\nlocal h: Holder = { circle = Circle.unit() }\n" ..
      "local f = h.circle.unit\n")
  assert(Programs.codes(field) == "field_unknown", Programs.codes(field))
  assert(field.errors[1].msg:find("`unit` is a function of the declaration `Circle` used as a value, and this is typed as a value of it", 1, true) ~= nil,
    field.errors[1].msg)
  local field_told = assert(field.errors[1]).fix
  assert(field_told:find("call it on the declaration: `Circle.unit(...)`", 1, true) ~= nil, field_told)
  assert(field_told:find("ceilings", 1, true) == nil and field_told:find("TODO", 1, true) == nil, field_told)
  -- a class says how to make a value instead
  local class = Programs.run("local class C\n  n: integer\nend\nlocal c: C = C\n")
  assert(class.errors[1].fix:find("make a value with a table literal", 1, true) ~= nil, class.errors[1].fix)
end

local function test_a_method_of_an_interface_is_called_on_its_receiver_and_never_read_as_a_value()
  local head = "local interface Sized\n  size: function(self: Sized): integer\nend\n" ..
    "local class Bag is Sized\n  items: {integer}\n  function size(self): integer\n    return #self.items\n  end\nend\n" ..
    "local class Num is Sized\n  n: integer\n  function size(self): integer\n    return self.n\n  end\nend\n" ..
    "local b: Bag = { items = { 1, 2 } }\nlocal n: Num = { n = 7 }\nlocal function make(): Sized\n  return n\nend\nlocal s: Sized = make()\n"
  -- the reviewer's program: another implementer is handed to the one function the value has
  refused(head .. "local f = s.size\nlocal x = f(b)\n", "interface_method_value",
    "`s.size` reads the method `size` of the interface `Sized` as a value, and its implementation depends on the receiver")
  refused(head .. "local x: integer = s.size(b)\n", "interface_method_value")
  local r = Programs.run(head .. "local f = s.size\n")
  assert(r.errors[1].fix == "call it as `s:size(...)`", r.errors[1].fix)
  -- called on its receiver it is fine, through the interface and a bound
  accepted(head .. "local x: integer = s:size()\nlocal y: integer = b:size()\n")
  accepted(head .. "local function total<T is Sized>(v: T): integer\n  return v:size()\nend\n")
  refused(head .. "local function total<T is Sized>(v: T): integer\n  return v.size(v)\nend\n", "interface_method_value")
  -- a class's method read through the class or an instance is one class's: its receiver is that class
  accepted(head .. "local g = Bag.size\nlocal h = b.size\nlocal x: integer = h(b)\n")
  refused(head .. "local x: integer = b.size(n)\n", "not_assignable")
  -- a function field of a record is a callback, and a field that is no method of the interface stays a field
  accepted("local interface Named\n  describe: function(self: Named, string): string\n  tag: function(string): string\nend\n" ..
      "local function f(v: Named): string\n  local g = v.tag\n  return g(\"x\")\nend\n")
end

local function test_calling_a_function_of_a_declaration_through_a_value_says_how_to_call_it()
  local class = "local class K\n  n: integer\nend\nfunction K.make(): K\n  return { n = 1 }\nend\nlocal k: K = K.make()\n"
  local r = Programs.run(class .. "local m = k.make\n")
  assert(Programs.codes(r) == "field_unknown" and r.errors[1].fix == "call it on the declaration: `K.make(...)`", r.errors[1].fix)
  local colon = Programs.run(class .. "local m = k:make()\n")
  assert(colon.errors[1].fix == "call it on the declaration: `K.make(...)`", colon.errors[1].fix)
  -- a record of this module read through a local or through a field has the function on its declaration
  local record = "local record Circle\n  radius: number\nend\nfunction Circle.unit(): Circle\n  return { radius = 1.0 }\nend\n" ..
    "local record Holder\n  circle: Circle\nend\nlocal c: Circle = Circle.unit()\nlocal h: Holder = { circle = c }\n"
  local local_read = Programs.run(record .. "local f = c.unit\n")
  assert(local_read.errors[1].fix == "call it on the declaration: `Circle.unit(...)`", local_read.errors[1].fix)
  local field_read = Programs.run(record .. "local f = h.circle.unit\n")
  assert(field_read.errors[1].fix == "call it on the declaration: `Circle.unit(...)`", field_read.errors[1].fix)
end

-- distinct names ----------------------------------------------------------------------------------------------

local function test_a_class_has_each_name_once_among_its_fields_methods_and_functions()
  declared_wrong("local class C\n  n: integer\n  function n(self)\n  end\nend\n", "repeated_field",
    "`n` is declared twice in `C`")
  declared_wrong("local class C\n  function m(self)\n  end\nend\nfunction C.m()\nend\n", "repeated_field",
    "a function `C.m` and a field or method of its values")
  declared_wrong("local class C\n  n: integer\nend\nfunction C.n()\nend\n", "repeated_field", "`n` is declared twice in `C`")
  accepted("local class C\n  n: integer\n  function m(self)\n  end\nend\nfunction C.make(): C\n  return { n = 1 }\nend\n")
end

-- metamethods -------------------------------------------------------------------------------------------------

local function test_a_close_method_takes_the_value_and_a_tostring_method_answers_a_string()
  accepted("local class G\n  n: integer\n  function __close(self)\n  end\n  function __tostring(self): string\n" ..
      "    return \"g\"\n  end\nend\n")
  accepted("local class G\n  function __close(self, err: any)\n  end\nend\n")
  declared_wrong("local class G\n  function __close(self, by: integer)\n  end\nend\n", "metamethod_signature",
    "the method `__close` of `G` takes more than the value")
  declared_wrong("local class G\n  function __tostring(self, indent: integer): string\n    return \"\"\n  end\nend\n",
    "metamethod_signature", "takes more than the value")
  declared_wrong("local class G\n  function __tostring(self): integer\n    return 1\n  end\nend\n", "metamethod_signature",
    "does not answer a `string`")
  declared_wrong("local class G\n  function __tostring(self)\n  end\nend\n", "metamethod_signature", "does not answer a `string`")
  declared_wrong("local class G\n  function __tostring(self): string, string\n    return \"\", \"\"\n  end\nend\n",
    "metamethod_signature", "does not answer a `string`")
end

local function test_no_other_metamethod_has_a_form_in_a_class()
  for _, name in ipairs({ "__index", "__newindex", "__call", "__gc", "__mode", "__len", "__eq", "__lt", "__concat", "__add",
      "__pairs", "__metatable", "__name", "__anything" }) do
    declared_wrong("local class C\n  function " .. name .. "(self)\n  end\nend\n", "class_metamethod",
      "the method `" .. name .. "` of `C` would be read by Lua as a metamethod")
  end
  declared_wrong("local class C\n  function m(self)\n  end\nend\nfunction C.__index()\nend\n", "class_metamethod",
    "the function `C.__index` is a name Lua reads as a metamethod")
  declared_wrong("local class C\n  function m(self)\n  end\nend\nfunction C.__close()\nend\n", "class_metamethod",
    "`__close` and `__tostring` are written as methods")
end

local function test_a_field_of_a_class_named_for_a_metamethod_is_refused_as_a_method_is()
  -- A value that lacks the field reads the table of its class for it, which holds the metamethods.
  for _, name in ipairs({ "__index", "__gc", "__close", "__anything" }) do
    declared_wrong("local class C\n  " .. name .. "?: integer\nend\n", "class_metamethod",
      "the field `" .. name .. "` of `C` is a name Lua reads as a metamethod")
  end
  -- a record's value is no class's table
  accepted("local record R\n  __index: integer\nend\nlocal r: R = { __index = 1 }\n")
end

-- `<close>` ---------------------------------------------------------------------------------------------------

local function test_a_close_local_holds_nil_or_a_class_that_declares_close()
  local head = "local class Guard\n  n: integer\n  function __close(self)\n  end\nend\n" ..
    "local class Plain\n  n: integer\nend\n"
  accepted(head .. "local g <close>: Guard = { n = 1 }\nlocal h <close>: Guard? = nil\nlocal i <close> = nil\n" ..
      "local function make(): Guard\n  return { n = 2 }\nend\nlocal j <close> = make()\n")
  refused(head .. "local p <close>: Plain = { n = 1 }\n", "close_not_closable",
    "`p` is a `<close>` local of `Plain`, and the class `Plain` declares no `__close`")
  refused(head .. "local p <close>: Plain? = nil\n", "close_not_closable")
  refused(head .. "local n <close> = 5\n", "close_not_closable", "`n` is a `<close>` local of `integer`, and `integer` is not a class")
  refused(head .. "local interface Closer\n  __close: function(self: Closer)\nend\nlocal function f(c: Closer)\n" ..
      "  local x <close> = c\nend\n", "close_not_closable", "`Closer` is not a class")
  refused(head .. "local s <close>: string = \"s\"\n", "close_not_closable")
  refused(head .. "local function f(v: any)\n  local a <close> = v\nend\n", "close_not_closable", "`a` is a `<close>` local of `any`")
  refused(head .. "local q <close>: Plain\n", "close_not_closable")
  refused(head .. "local both <close>: Guard | Plain\n", "close_not_closable")
  -- the declaration of a class with `__close`, used as a value, is no class value
  refused(head .. "local d <close> = Guard\n", "close_not_closable", "`Guard (declaration)`")
end

local function test_a_close_local_holds_a_class_a_module_answers_with_a_failure()
  -- The shape of the signal module's guard: a class that implements an interface, answered as `T?, string` and held as
  -- `local g <close> = assert(M.guard())`, where `assert` narrows the optional.
  local modules: {string: string} = { held = "local interface Held\n  n: integer\nend\n" ..
      "local class Guard is Held\n  n: integer\n  function __close(self)\n  end\nend\n" ..
      "local record Held_module\n  type Guard = Guard\n  guard: function(): Guard?, string\nend\n" ..
      "function Held_module.guard(): Guard?, string\n  local g: Guard = { n = 1 }\n  return g, \"\"\nend\n" ..
      "return Held_module\n" }
  local head = "local Held = require(\"held\")\n"
  accepted(head .. "local g <close> = assert(Held.guard())\n", modules)
  accepted(head .. "local g <close>: Held.Guard = assert(Held.guard())\n", modules)
  -- the record that sets its metatable by hand, the shape the signal guard had, is still no value to close
  local record_modules: {string: string} = { held = "local record Guard\n  n: integer\n  __close: function(Guard)\nend\n" ..
      "local record Held_module\n  type Guard = Guard\n  guard: function(): Guard?, string\nend\n" ..
      "return Held_module\n" }
  refused(head .. "local g <close> = assert(Held.guard())\n", "close_not_closable",
    "`Guard` is not a class or a userdata record", record_modules)
end

local DEV <const> = "local record dev\n" ..
  "  record Handle\n    userdata\n    __close: function(self: Handle)\n    fd: function(self: Handle): integer\n  end\n" ..
  "  record Bare\n    userdata\n    fd: function(self: Bare): integer\n  end\n" ..
  "  record Empty\n    userdata\n  end\n" ..
  "  record Odd\n    userdata\n    __close: integer\n  end\n" ..
  "  record Maybe\n    userdata\n    __close?: function(self: Maybe)\n  end\n" ..
  "  record NoSelf\n    userdata\n    __close: function()\n  end\n" ..
  "  record AnySelf\n    userdata\n    __close: function(self: any)\n  end\n" ..
  "  record Super\n    userdata\n    __close: function(self: Closer)\n  end\n" ..
  "  record MutSelf\n    userdata\n    __close: function(self: mut MutSelf)\n  end\n" ..
  "  record Over\n    userdata\n    __close: function(self: Over, a: integer)\n    __close: function(self: Over)\n  end\n" ..
  "  record Other\n    userdata\n    __close: function(other: Bare)\n  end\n" ..
  "  record TwoMore\n    userdata\n    __close: function(self: TwoMore, a: integer, b: integer)\n  end\n" ..
  "  record Err\n    userdata\n    __close: function(self: Err, err: any)\n  end\n" ..
  "  record ErrInt\n    userdata\n    __close: function(self: ErrInt, err: integer)\n  end\n" ..
  "  record Answers\n    userdata\n    __close: function(self: Answers): integer\n  end\n" ..
  "  interface Closer\n    __close: function(self: Closer)\n  end\n" ..
  "  record Inherits\n    userdata\n    is Closer\n    fd: function(self: Inherits): integer\n  end\n" ..
  "  open: function(): Handle?\n  make: function(): Handle\n  bare: function(): Bare\n  empty: function(): Empty\n" ..
  "  odd: function(): Odd\n  maybe: function(): Maybe\n  noself: function(): NoSelf\n  other: function(): Other\n" ..
  "  anyself: function(): AnySelf\n  super: function(): Super\n  mutself: function(): MutSelf\n  over: function(): Over\n  twomore: function(): TwoMore\n  err: function(): Err\n  errint: function(): ErrInt\n  answers: function(): Answers\n" ..
  "  closer: function(): Closer\n  inherits: function(): Inherits\n" ..
  "end\nreturn dev\n"

--- `body`, a program that requires the module `module` as `dev`.
local function with_dev(module: string, body: string): string
  return "local dev = require(\"" .. module .. "\")\n" .. body
end

local function test_a_close_local_holds_a_userdata_record_that_declares_close_as_a_method()
  -- from any module: the declaration is taken as true, in the core's or a program's
  for _, module in ipairs({ "dev", "cosmic.internal.dev" }) do
    accepted(with_dev(module, "local h <close> = dev.open()\nlocal g <close> = dev.make()\n" ..
        "local function f(handle: dev.Handle)\n  local x <close> = handle\nend\n"), nil, { [module] = DEV })
  end
end

local function test_a_userdata_record_without_a_close_method_is_not_closable()
  local declared = { dev = DEV }
  local function bad(call: string, why: string)
    refused(with_dev("dev", "local x <close> = dev." .. call .. "()\n"), "close_not_closable", why, nil, declared)
  end
  bad("bare", "the userdata record `dev.Bare` declares no `__close` method")
  bad("empty", "declares no `__close` method")
  -- a field of that name is no method: not a function, or optional, or without the record first
  bad("odd", "as a field and not a method")
  bad("maybe", "as a field and not a method")
  bad("noself", "as a field and not a method")
  bad("other", "as a field and not a method")
  bad("anyself", "as a field and not a method")
  bad("super", "as a field and not a method")
  bad("mutself", "as a field and not a method")
  -- an interface's `__close` is no metatable's, whether the local is typed by the interface or the record lists it
  bad("inherits", "declares no `__close` method")
  refused(with_dev("dev", "local x <close> = dev.closer()\n"), "close_not_closable", "is not a class", nil, declared)
end

local function test_a_close_method_must_take_the_value_alone_and_answer_nothing()
  local declared = { dev = DEV }
  accepted(with_dev("dev", "local x <close> = dev.err()\n"), nil, declared)
  -- every overload must be one, not just one of them
  for _, call in ipairs({ "twomore", "errint", "answers", "over" }) do
    refused(with_dev("dev", "local x <close> = dev." .. call .. "()\n"), "close_not_closable",
      "declares a `__close` that is not what Lua calls", nil, declared)
  end
  declared_wrong("local class G\n  function __close(self): integer\n    return 1\n  end\nend\n", "metamethod_signature",
    "or answers a value")
end

local function test_a_union_with_a_member_that_is_not_closable_is_refused_naming_it()
  local declared = { dev = DEV }
  for _, other in ipairs({ "false", "boolean", "integer" }) do
    refused(with_dev("dev", "local function f(h: dev.Handle | " .. other .. ")\n  local x <close> = h\nend\n"),
      "close_not_closable", "of the union is not closable", nil, declared)
  end
  refused(with_dev("dev", "local function f(h: dev.Handle | dev.Bare)\n  local x <close> = h\nend\n"),
    "close_not_closable", "the member `dev.Bare` (of dev) of the union", nil, declared)
end

local function test_the_standard_library_s_userdata_are_closable_where_they_declare_close()
  local checks = Programs.session((assert(Fs.read("lang/prelude.d.tl"))), (assert(Fs.read("lang/stdlib.d.tl"))))
  local sources = {
    "local function f(v: debug.Userdata)\n  local x <close> = v\nend\n",
    "local function f(v: Coroutine<integer, nil, nil>)\n  local x <close> = v\nend\n",
    "local function f(v: Yielder<integer, nil>)\n  local x <close> = v\nend\n",
  }
  -- a file declares `__close`, as Lua's do
  local file = checks("local x <close> = io.stdout\n", "std0")
  assert(#file.before == 0 and Programs.codes(file) == "", Programs.codes(file))
  for i, source in ipairs(sources) do
    local r = checks(source, "std" .. tostring(i))
    assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
    assert(Programs.codes(r) == "close_not_closable", Programs.codes(r) .. " in\n" .. source)
  end
end

-- `is` --------------------------------------------------------------------------------------------------------

local function test_is_of_a_class_is_allowed_and_is_of_a_record_is_not()
  local head = "local class C\n  n: integer\nend\nlocal record R\n  n: integer\nend\n"
  accepted(head .. "local function f(v: any): boolean\n  return v is C\nend\n")
  accepted(head .. "local function f(v: C | string): boolean\n  return v is C\nend\n")
  refused(head .. "local function f(v: any): boolean\n  return v is R\nend\n", "is_on_record", "a record leaves nothing to test")
  refused("local interface I\n  n: integer\nend\nlocal function f(v: any): boolean\n  return v is I\nend\n", "is_on_record",
    "an interface leaves nothing to test")
end

local function test_is_of_a_generic_class_cannot_tell_the_arguments_and_is_refused()
  refused("local class Box<T>\n  item: T\nend\nlocal function f(v: any): boolean\n  return v is Box<integer>\nend\n", "is_on_record",
    "the metatable tells the class and not its type arguments")
end

local function test_is_of_a_class_of_another_module_is_out_of_reach()
  local modules: {string: string} = { other = "local class K\n  n: integer\nend\nreturn K\n" }
  refused("local type K = require(\"other\")\nlocal function f(v: any): boolean\n  return v is K\nend\n", "class_scope",
    "tests the metatable of a class of the module `other`", modules)
end

-- a declaration used as a value -----------------------------------------------------------------------------

local function test_a_declaration_used_as_a_value_has_a_type_of_its_own()
  local r = Programs.run(COUNTER .. "local value = Counter\nlocal c: Counter = { n = 0 }\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  local value, instance = Programs.var(r, "value"), Programs.var(r, "c")
  assert(value ~= instance and Types.display(value) == "Counter (declaration)" and Types.display(instance) == "Counter")
  assert((value.tag == "named") and (instance.tag == "named") and value.value and not instance.value and
      value.decl == instance.decl)
  refused(COUNTER .. "local c: Counter = { n = 0 }\nlocal value = Counter\nvalue = c\n", "declaration_value",
    "is a value of `Counter`, where the declaration `Counter` itself is wanted")
end

local function test_the_statics_of_a_record_are_fields_of_its_declaration_and_not_of_its_values()
  local record = "local record Circle\n  radius: number\nend\nfunction Circle.unit(): Circle\n  return { radius = 1.0 }\nend\n"
  accepted(record .. "local c: Circle = Circle.unit()\nlocal r: number = c.radius\n")
  refused(record .. "local c: Circle = Circle.unit()\nlocal f = c.unit\n", "field_unknown", "`Circle` has no field `unit`")
  refused(record .. "local c: Circle = Circle\n", "declaration_value")
  -- a literal of the record gives the fields it declares and not the functions
  accepted(record .. "local c: Circle = { radius = 2.0 }\n")
  -- the value of the module is the declaration: its functions, called as such
  accepted(record .. "local make = Circle.unit\nlocal c: Circle = make()\n")
  local modules: {string: string} = { circles = record .. "return Circle\n" }
  accepted("local Circles = require(\"circles\")\nlocal c = Circles.unit()\n", modules)
  refused("local type Circle = require(\"circles\")\nlocal Circles = require(\"circles\")\nlocal c: Circle = Circles\n",
    "declaration_value", nil, modules)
end
