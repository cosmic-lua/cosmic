--- Tests of [`lang.declarations`]: a case for each rule it holds a declaration to, each error with its
--- code, place, message and fix, and what a lowered module gives the checker (the types of its
--- annotations, the declarations of its types, what it exports).
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Programs = require("lang.declarations_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local function fresh(): Declarations.Program
  return Declarations.new()
end

--- The errors of lowering `source` as a module alone.
local function errors_of(source: string, dialect?: Ast.Dialect): {Declarations.Error}
  return Programs.lower(fresh(), "t", source, dialect).lowered.errors
end

--- The one error of `source`.
local function only(source: string): Declarations.Error
  local errors = errors_of(source)
  assert(#errors == 1, #errors .. " errors in\n" .. source)
  return errors[1]
end

local function has(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

--- The body of the declaration `name` of `module`.
local function body_of(program: Declarations.Program, module: string, name: string): Types.Body
  local decl = program.store:find(module, name)
  assert(decl ~= nil, name .. " is not declared")
  local body = decl.body
  assert(body ~= nil, name .. " has no body")
  return body
end

--- The type of the `i`th annotation of the `local` statement `stat` of a lowered source.
local function annotation(result: Programs.Result, stat: integer, i?: integer): Types.Type
  local s = result.chunk.body.stats[stat]
  assert(s is Ast.Local)
  return result.lowered.types[s.types[i or 1].id]
end

--- Interfaces that each list the next twice with other arguments: `rungs` of them have a closure of 2^rungs.
local function ladder(rungs: integer): string
  local out: {string} = {}
  for i = 1, rungs do
    if i < rungs then
      out[#out + 1] = "local interface Rung" .. i .. "<T> is Rung" .. (i + 1) .. "<{T}>, Rung" .. (i + 1) ..
        "<{integer: T}>\nend\n"
    else
      out[#out + 1] = "local interface Rung" .. i .. "<T>\nend\n"
    end
  end
  return table.concat(out)
end

--- A case for each code: a source with one mistake, and what its message and fix say.
local record Case
  code: Declarations.Code
  source: string
  msg: string
  fix: string
end

local CASES <const>: {Case} = {
  {
    code = "listing_too_large",
    source = ladder(14),
    msg = "`Rung1` lists more interfaces, through the ones it lists, than the checker follows",
    fix = "list fewer interfaces, or interfaces whose own listings are the same for every argument",
  },
  {
    code = "interface_disagrees",
    source = "local interface I\n  n: integer\nend\nlocal record R is I\n  n: string\nend\n",
    msg = "`R.n` is `string`, but `I` declares it as `integer`",
    fix = "change `R.n` to `integer`: a type that lists an interface declares each of its fields with exactly the interface's type",
  },
  {
    code = "super_not_interface",
    source = "local record A\nend\nlocal class C is A\nend\n",
    msg = "`C` lists `A`, which is a record, and only an interface can follow `is`",
    fix = "list an interface here, or declare `A` as an interface",
  },
  {
    code = "super_cycle",
    source = "local interface I is I\nend\n",
    msg = "`I` lists itself",
    fix = "remove `I` from what `I` lists: a declaration lists the interfaces it implements or extends, never itself",
  },
  {
    code = "untagged_union",
    source = "local record A\n  kind: string\nend\nlocal record B\n  kind: string\nend\nlocal type U = A | B\n",
    msg = "the union `A | B` holds 2 records that have no tag",
    fix = "a fixed field of the same name whose type is an enum of one value each, different in each",
  },
  {
    code = "array_of_optional",
    source = "local x: {string?}\n",
    msg = "the elements of `{string?}` may be nil, and an array is dense",
    fix = "use a map `{integer: string}` for sparse data, or write `{string}` and keep the missing elements out",
  },
  {
    code = "float_key",
    source = "local x: {number: string}\n",
    msg = "a map is keyed by `integer`, not `number`",
    fix = "key by `integer`, and convert a float with `math.tointeger(n)` or `math.floor(n)`",
  },
  {
    code = "key_type",
    source = "local x: {string | integer: string}\n",
    msg = "a map is not keyed by a union",
    fix = "key by `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata",
  },
  {
    code = "repeated_field",
    source = "local class C\n  n: integer\n  function n(self)\n  end\nend\n",
    msg = "`n` is declared twice in `C`",
    fix = "rename or remove one of them: the fields and methods of a record or class share one namespace",
  },
  {
    code = "repeated_value",
    source = "local enum E \"x\" \"y\" \"x\" end\n",
    msg = "the value `x` is written twice in the enum `E`",
    fix = "remove the second `x`: an enum is the set of its values",
  },
  {
    code = "type_arguments",
    source = "local record R<T>\n  f: T\nend\nlocal x: R\n",
    msg = "`R` takes 1 type argument, not 0",
    fix = "write `R<T>`, with a type for each parameter",
  },
  {
    code = "alias_cycle",
    source = "local type A = B\nlocal type B = A\n",
    msg = "the alias `A` names itself, with no declaration between",
    fix = "declare a record for the part of `A` that reaches itself",
  },
  {
    code = "bound_not_interface",
    source = "local record R\nend\nlocal function f<T is R>(x: T)\nend\n",
    msg = "`T` is bounded by `R`, which is not an interface used with no type arguments",
    fix = "bound `T` by an interface that takes no type parameters, or write no bound",
  },
  {
    code = "lists_overlap",
    source = "local type Reply = function(): (integer, string) | (string, integer)\n",
    msg = "the return lists `(integer, string)` and `(string, integer)` are told apart by no position that is `true` in one and `false` in the other",
    fix = "make one position `true` in one list and `false` in the other (`(true, R) | (false, E)`)",
  },
  {
    code = "bound_not_met",
    source = "local interface Named\n  name: string\nend\nlocal record Plain\n  name: string\nend\n" ..
      "local record Box<T is Named>\n  value: T\nend\nlocal b: Box<Plain>\n",
    msg = "`Box` bounds its type parameter 1 by `Named`, and `Plain` does not list it",
    fix = "list the interface in the declaration of `Plain` (`is Named`), or pass a type that does",
  },
  {
    code = "outer_type_parameter",
    source = "local function f<T>(x: T)\n  local record Inner\n    v: T\n  end\nend\n",
    msg = "`T` is a type parameter of the code around this declaration, which a declaration cannot name",
    fix = "give the declaration a type parameter of its own and pass `T` to it",
  },
  {
    code = "member_missing",
    source = "local record Stream\nend\nlocal x: Stream.Reader\n",
    msg = "`Stream` declares no type `Reader`",
    fix = "declare `Reader` inside `Stream`, or name a type it does declare",
  },
  {
    code = "param_untyped",
    source = "local class C\n  function m(self, n)\n  end\nend\n",
    msg = "the parameter `n` of the method `m` has no type",
    fix = "write the type: `n: T`",
  },
  {
    code = "metamethod_signature",
    source = "local class C\n  function __close(self, by: integer)\n  end\nend\n",
    msg = "the method `__close` of `C` takes more than the value",
    fix = "write `function __close(self)`",
  },
  {
    code = "class_metamethod",
    source = "local class C\n  function __call(self)\n  end\nend\n",
    msg = "the method `__call` of `C` would be read by Lua as a metamethod of its values",
    fix = "rename `__call` and call it as a method (`v:call(...)`)",
  },
  {
    code = "optional_metamethod",
    source = "local record R\n  metamethod __index?: function(R, string): any\nend\n",
    msg = "the field `__index` of `R` is named for a metamethod and may be nil, so Lua may find it missing where it calls it",
    fix = "make `__index` a field the literal always gives, or rename it",
  },
  {
    code = "optional_generic",
    source = "local record R\n  pick?: function<T>(T): T\nend\n",
    msg = "the field `pick` of `R` may be nil and holds a generic function, which the checker has no rule to narrow and call",
    fix = "make `pick` a field the literal always gives, or write the function type with its type arguments fixed",
  },
  {
    code = "unused_type_parameter",
    source = "local function pick<T, U>(x: T): T\n  return x\nend\n",
    msg = "the type parameter `U` is named by no parameter and no result, so no call can fix it",
    fix = "remove `U` from the type parameters, or use it in a parameter or a result",
  },
  {
    code = "metamethod_unknown",
    source = "local record R\n  __nope: function(R)\nend\n",
    msg = "the field `__nope` of `R` begins with two underscores, which Lua reads as a metamethod, and Lua has no metamethod of that name",
    fix = "rename `__nope` without the leading underscores, or write the name of the metamethod you mean",
  },
  {
    code = "array_part_map",
    source = "local record R is {string: integer}\nend\n",
    msg = "`R` is declared `is {string: integer}`, which makes it a map, and the array part of a record is a `{T}`",
    fix = "write `is {T}` for an array part, or declare the fields of `R` and a field of type `{string: integer}`",
  },
  {
    code = "thread_type",
    source = "local x: thread\n",
    msg = "`thread` is no type",
    fix = "write `Coroutine<Y, R, S>` with the type it yields, returns and is sent",
  },
}

--- Code, message and fix for the sources above.
local function test_each_code_has_an_error_with_its_message_and_fix()
  local seen: {string: boolean} = {}
  for _, case in ipairs(CASES) do
    local errors = errors_of(case.source)
    local found: Declarations.Error | nil
    for _, e in ipairs(errors) do
      if e.code == case.code and found == nil then
        found = e
      end
    end
    assert(found ~= nil, case.code .. " is not reported for\n" .. case.source)
    assert(has(found.msg, case.msg), found.msg)
    assert(has(found.fix, case.fix), found.fix)
    assert(found.y > 0 and found.x > 0 and found.length > 0 and found.filename == "t.tl")
    seen[case.code] = true
  end
  -- type_too_deep and store_refused are checked below and by the property test.
  for _, code in ipairs(Declarations.codes) do
    assert(seen[code] or code == "type_too_deep" or code == "store_refused", code .. " has no case")
  end
end

local function test_the_catalog_holds_a_row_for_each_code_once()
  local rows: {string: Declarations.Row} = {}
  for _, row in ipairs(Declarations.catalog) do
    assert(rows[row.code] == nil, row.code .. " twice")
    rows[row.code] = row
    assert(row.rule ~= "" and row.why ~= "" and row.fix ~= "")
  end
  assert(#Declarations.catalog == #Declarations.codes)
  for i, code in ipairs(Declarations.codes) do
    assert(Declarations.catalog[i].code == code, code)
  end
end

local function test_an_error_names_the_types_it_is_about_as_the_program_spells_them()
  local e = only("local x: {string?}\n")
  assert(#e.types == 1 and e.types[1] == "string?")
  local d = only("local interface I\n  f: function(I, n?: integer): string\nend\nlocal record R is I\n  f: function(R, n?: integer): integer\nend\n")
  assert(d.code == "interface_disagrees" and #d.types == 2 and d.types[2] == "function(R, p2?: integer): string", d.types[2])
end

-- optional fields -------------------------------------------------------------------------

local function test_a_field_that_may_be_nil_is_never_a_metamethod_and_never_a_generic_function_in_any_spelling()
  local refused: {string: Declarations.Code} = {
    ["metamethod __index?: function(R, string): any"] = "optional_metamethod",
    ["__index?: function(R, string): any"] = "optional_metamethod",
    ["__close: function(R)?"] = "optional_metamethod",
    ["pick?: function<T>(T): T"] = "optional_generic",
    ["pick: (function<T>(T): T)?"] = "optional_generic",
    ["pick: (function<T>(T): T) | nil"] = "optional_generic",
  }
  for field, code in pairs(refused) do
    local e = only("local record R\n  " .. field .. "\nend\n")
    assert(e.code == code, field .. " is " .. e.code)
    assert(e.y == 2 and e.length > 0, field)
  end
  -- through an alias and in an interface, and the same field when it is required
  assert(only("local type G = function<T>(T): T\nlocal record R\n  pick?: G\nend\n").code == "optional_generic")
  assert(only("local interface I\n  pick?: function<T>(T): T\nend\n").code == "optional_generic")
  assert(#errors_of("local record R\n  __index: function(R, string): any\n  pick: function<T>(T): T\nend\n") == 0)
  -- a type parameter that the declaration makes optional is not filled with a generic function either, in the
  -- declaration or through another one that passes it on
  local generic = "function<T>(T): T"
  for _, optional in ipairs({ "v?: X", "v: X?" }) do
    local box = "local record Box<X>\n  " .. optional .. "\nend\n"
    assert(only(box .. "local b: Box<" .. generic .. ">\n").code == "optional_generic", optional)
    assert(only(box .. "local record Outer<Y>\n  inner: Box<Y>\nend\nlocal o: Outer<" .. generic .. ">\n").code ==
        "optional_generic", optional)
    assert(only(box .. "local type Alias<Z> = Box<Z>\nlocal a: Alias<" .. generic .. ">\n").code == "optional_generic", optional)
    -- a function type with its type arguments fixed, and a required field, are plain
    assert(#errors_of(box .. "local b: Box<function(integer): integer>\n") == 0, optional)
  end
  assert(#errors_of("local record Plain<X>\n  v: X\nend\nlocal p: Plain<" .. generic .. ">\n") == 0)
  -- an optional field of any other name and function type is a plain value
  assert(#errors_of("local record R\n  done?: function(code: integer)\n  index?: function(R, string): any\nend\n") == 0)
end

local function test_a_type_parameter_that_no_parameter_or_result_names_is_unused_in_every_spelling_of_a_function()
  local function unused(source: string): string
    local names: {string} = {}
    for _, e in ipairs(errors_of(source)) do
      names[#names + 1] = e.code
    end
    return table.concat(names, " ")
  end
  -- a function statement, a method-less static, a function type and a field of function type
  assert(unused("local function f<T>(): integer\n  return 1\nend\n") == "unused_type_parameter")
  assert(unused("local record R\nend\nfunction R.make<T>(): integer\n  return 1\nend\n") == "unused_type_parameter")
  assert(unused("local type F = function<T>(): integer\n") == "unused_type_parameter")
  assert(unused("local record R\n  make: function<T>(integer): integer\nend\n") == "unused_type_parameter")
  assert(unused("local function f<T, U>(a: T): integer\n  return 1\nend\n") == "unused_type_parameter")
  -- one named by a parameter, a result, a rest parameter, an array, a map, a generic record, a nested function type
  assert(unused("local function f<T>(a: T) end\n") == "")
  assert(unused("local function f<T>(): T\n  error('x')\nend\n") == "")
  assert(unused("local function f<T>(...: T) end\n") == "")
  assert(unused("local function f<T>(a: {T}) end\n") == "")
  assert(unused("local function f<T>(a: {string: T}) end\n") == "")
  assert(unused("local record Box<X>\n  v: X\nend\nlocal function f<T>(a: Box<T>) end\n") == "")
  assert(unused("local function f<T>(g: function(T): integer) end\n") == "")
  assert(unused("local function f<T>(g: function<U>(U, T): integer) end\n") == "")
  assert(unused("local function f<T>(): function(T) end\n") == "")
  assert(unused("local function f<T>(): T...\n  error('x')\nend\n") == "")
  -- a variable of the function around is not the one the inner function declares
  assert(unused("local function f<T>(g: function<U>(T): integer) end\n") == "unused_type_parameter")
  -- a signature that is already refused for what it names is told once
  assert(unused("local function f<T>(x: T<integer>)\nend\n") == "type_arguments")
end

local function test_a_field_named_with_two_underscores_is_the_name_of_a_lua_metamethod_or_refused()
  local function codes(field: string, kind?: string): string
    local names: {string} = {}
    for _, e in ipairs(errors_of("local " .. (kind or "record") .. " R\n  " .. field .. "\nend\n")) do
      names[#names + 1] = e.code
    end
    return table.concat(names, " ")
  end
  for _, name in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__idiv", "__band", "__bor", "__bxor",
      "__bnot", "__shl", "__shr", "__concat", "__len", "__eq", "__lt", "__le", "__index", "__newindex", "__call", "__close",
      "__gc", "__mode", "__tostring", "__name", "__metatable", "__pairs" }) do
    assert(codes(name .. ": function(R)") == "", name)
  end
  for _, name in ipairs({ "__nope", "__fact", "__is", "__", "__Index", "__ipairs" }) do
    assert(codes(name .. ": function(R)") == "metamethod_unknown", name)
    assert(codes("metamethod " .. name .. ": function(R)") == "metamethod_unknown", name)
    assert(codes(name .. ": integer", "interface") == "metamethod_unknown", name)
  end
  -- one underscore, a name inside, and a class (which refuses every such name as its own mistake)
  assert(codes("_nope: function(R)") == "" and codes("nope__: function(R)") == "")
  assert(codes("__nope: integer", "class") == "class_metamethod")
  -- an optional one is the mistake of being optional and of the name, each once
  assert(codes("__nope?: function(R)") == "optional_metamethod metamethod_unknown")
end

local function test_the_array_part_of_a_record_is_a_sequence_and_not_a_map()
  local function codes(head: string): string
    local names: {string} = {}
    for _, e in ipairs(errors_of("local record R is " .. head .. "\n  x: integer\nend\n")) do
      names[#names + 1] = e.code
    end
    return table.concat(names, " ")
  end
  assert(codes("{string}") == "" and codes("{integer}") == "")
  assert(codes("{string: integer}") == "array_part_map" and codes("{integer: string}") == "array_part_map")
end

-- agreement ------------------------------------------------------------------------------

local function test_a_type_that_has_each_field_of_its_interface_agrees_and_its_receiver_is_its_own()
  local program = fresh()
  local result = Programs.lower(program, "cosmic.stream", Programs.stream_source)
  assert(#result.lowered.errors == 0)
  local source = [[
local type Stream = require("cosmic.stream")
local class File is Stream.Reader
  function read(self, max_bytes?: integer): string?
    return nil
  end
end
local record Plain is Stream.Reader
  read: function(Plain, max_bytes?: integer): string?
end
]]
  local lowered = Programs.lower(program, "m", source).lowered
  assert(#lowered.errors == 0, Programs.codes(lowered))
end

local function test_a_missing_field_a_fixed_field_declared_mut_and_a_required_one_declared_omittable_disagree()
  local base = "local interface I\n  mut a: integer\n  b?: integer\n  c: integer\nend\n"
  local missing = only(base .. "local record R is I\n  mut a: integer\n  b?: integer\nend\n")
  assert(missing.code == "interface_disagrees" and has(missing.msg, "`R` lists `I` but has no field `c`"), missing.msg)
  assert(has(missing.fix, "declare `c: integer` in `R`, as `I` declares it"), missing.fix)
  local fixed = only(base .. "local record R is I\n  a: integer\n  b?: integer\n  c: integer\nend\n")
  assert(has(fixed.msg, "`R.a` is fixed, but `I` declares it `mut`") and has(fixed.fix, "declare `mut a` in `R`"), fixed.msg)
  local mutable = only(base .. "local record R is I\n  mut a: integer\n  b?: integer\n  mut c: integer\nend\n")
  assert(has(mutable.msg, "`R.c` is mut, but `I` declares it fixed") and has(mutable.fix, "remove `mut` from `R.c`"), mutable.msg)
  local required = only(base .. "local record R is I\n  mut a: integer\n  b: integer?\n  c: integer\nend\n")
  assert(has(required.msg, "`R.b` is required, but `I` declares it omittable"), required.msg)
  assert(has(required.fix, "write `b?:` in `R`"), required.fix)
end

local function test_the_fields_of_the_interfaces_an_interface_extends_and_their_arguments_are_agreed_with()
  local source = [[
local interface Source<T>
  next: function(Source<T>): T?
end
local interface Named is Source<string>
  name: string
end
local record Good is Named
  name: string
  next: function(Good): string?
end
local record Bad is Named
  name: string
  next: function(Bad): integer?
end
]]
  local e = only(source)
  assert(e.code == "interface_disagrees" and has(e.msg, "`Bad.next` is `function(Bad): integer?`, but `Source<string>` declares it as `function(Bad): string?`"), e.msg)
end

local function test_an_interface_that_redeclares_a_field_of_one_it_extends_must_agree_and_may_leave_it_out()
  local base = "local interface A\n  n: integer\nend\n"
  assert(#errors_of(base .. "local interface B is A\nend\n") == 0)
  assert(#errors_of(base .. "local interface B is A\n  n: integer\nend\n") == 0)
  local e = only(base .. "local interface B is A\n  n: string\nend\n")
  assert(e.code == "interface_disagrees" and has(e.msg, "`B.n` is `string`, but `A` declares it as `integer`"), e.msg)
end

local function test_a_method_satisfies_a_function_field_and_a_mut_field_wants_a_field()
  local base = "local interface I\n  f: function(I)\n  mut g: function(I)\nend\n"
  local e = only(base .. "local class C is I\n  mut g: function(C)\n  function f(self)\n  end\n  function g(self)\n  end\nend\n")
  assert(e.code == "repeated_field", e.code)
  local ok = errors_of(base .. "local class C is I\n  mut g: function(C)\n  function f(self)\n  end\nend\n")
  assert(#ok == 0, ok[1] and ok[1].msg or "")
  local bad = only(base .. "local class C is I\n  function f(self)\n  end\n  function g(self)\n  end\nend\n")
  assert(has(bad.msg, "`C.g` is fixed, but `I` declares it `mut`"), bad.msg)
end

local function test_a_listing_that_cycles_or_lists_what_is_no_interface_is_refused_and_dropped()
  local both = errors_of("local interface J is K\nend\nlocal interface K is J\nend\n")
  assert(#both == 1 and both[1].code == "super_cycle" and has(both[1].msg, "`K` lists `J`, which lists `K`"), both[1] and both[1].msg or "")
  local enum = only("local enum E \"a\" end\nlocal record R is E\nend\n")
  assert(enum.code == "super_not_interface" and has(enum.msg, "which is a enum"), enum.msg)
  -- the listing is dropped, so nothing else is said of R
  local program = fresh()
  local lowered = Programs.lower(program, "t", "local record A\nend\nlocal class C is A\n  n: integer\nend\n").lowered
  assert(#body_of(program, "t", "C").supers == 0 and #lowered.errors == 1)
end

local function test_a_ladder_of_listings_with_different_arguments_is_refused_as_too_large()
  assert(#errors_of(ladder(12)) == 0)
  local e = errors_of(ladder(14))
  assert(#e == 2 and e[1].code == "listing_too_large" and has(e[1].msg, "`Rung1` lists more interfaces"), #e)
  assert(has(e[1].fix, "list fewer interfaces"))
end

local function test_an_omittable_function_field_agrees_with_the_receiver_replaced_and_is_still_held_to_the_interface()
  local base = "local interface I\n  mut skip?: function(I, n: integer): boolean\nend\n"
  assert(#errors_of(base .. "local record R is I\n  mut skip?: function(R, n: integer): boolean\nend\n") == 0)
  assert(#errors_of(base .. "local class C is I\n  mut skip?: function(C, n: integer): boolean\nend\n") == 0)
  local missing = only(base .. "local record R is I\nend\n")
  assert(has(missing.msg, "`R` lists `I` but has no field `skip`") and has(missing.fix, "declare `mut skip?: function(R, integer): boolean`"), missing.fix)
  local required = only(base .. "local record R is I\n  mut skip: function(R, n: integer): boolean\nend\n")
  assert(has(required.msg, "`R.skip` is `function(R, integer): boolean`, but `I` declares it as"), required.msg)
  local fixed = only(base .. "local record R is I\n  skip?: function(R, n: integer): boolean\nend\n")
  assert(has(fixed.msg, "`R.skip` is fixed, but `I` declares it `mut`"), fixed.msg)
  local method = only(base .. "local class C is I\n  function skip(self, n: integer): boolean\n    return true\n  end\nend\n")
  assert(method.code == "interface_disagrees", method.code)
end

local function test_the_fix_of_a_missing_field_shows_the_types_in_the_names_the_declaration_gives_and_never_invalid()
  local generic = only("local interface Source<T>\n  next: function(Source<T>): T?\nend\nlocal record Box<T> is Source<T>\nend\n")
  assert(has(generic.msg, "`Box` lists `Source<T>` but has no field `next`"), generic.msg)
  assert(has(generic.fix, "declare `next: function(Box<T>): T?` in `Box`"), generic.fix)
  assert(not has(generic.fix, "?0.0"))
  -- a field typed by a name nothing declares is invalid, and the fix says only to declare it
  local program = fresh()
  local result = Programs.lower(program, "t", "local interface I\n  a: Missing\nend\nlocal record R is I\nend\n")
  local e = result.lowered.errors[1]
  assert(#result.lowered.errors == 1 and e.code == "interface_disagrees" and not has(e.fix, "invalid") and has(e.fix, "declare `a` in `R`"), e and e.fix or "")
end

local function test_an_alias_in_a_function_body_or_repeated_at_the_top_is_lowered_and_held_to_the_rules()
  local body = errors_of("local function f()\n  local type A = {string?}\n  local x: A\nend\n")
  assert(#body == 1 and body[1].code == "array_of_optional", #body .. " " .. (body[1] and body[1].code or ""))
  local used = errors_of("local function f()\n  local type A = {integer}\n  local x: A\n  local y: A\nend\n")
  assert(#used == 0, used[1] and used[1].msg or "")
  local twice = errors_of("local type A = integer\nlocal type A = {number: string}\nlocal x: A\n")
  local codes: {string} = {}
  for i, e in ipairs(twice) do
    codes[i] = e.code
  end
  assert(table.concat(codes, " ") == "float_key", table.concat(codes, " "))
  local cycle = errors_of("local function f()\n  local type A = B\n  local type B = A\nend\n")
  assert(#cycle >= 1 and cycle[1].code == "alias_cycle", cycle[1] and cycle[1].code or "none")
end

local function test_an_alias_that_names_a_type_parameter_of_the_code_around_it_is_refused()
  local record = only("local record Outer<T>\n  type Al = {T}\n  items: Al\nend\n")
  assert(record.code == "outer_type_parameter" and has(record.msg, "`T` is a type parameter of the code around this declaration"), record.msg)
  local fn = only("local function f<T>(x: T)\n  local type A = {T}\n  local y: A\nend\n")
  assert(fn.code == "outer_type_parameter", fn.code)
  -- its own parameters are fine
  assert(#errors_of("local function f<T>(x: T)\n  local type A<U> = {U}\n  local y: A<T>\nend\n") == 0)
end

-- tags ---------------------------------------------------------------------------------------

local TAGS <const> = [[
local enum AK "a" end
local enum BK "b" end
local record A
  kind: AK
end
local record B
  kind: BK
end
]]

local function test_a_union_of_records_with_a_fixed_single_valued_enum_tag_each_is_legal()
  assert(#errors_of(TAGS .. "local type U = A | B\nlocal x: A | B | nil\n") == 0)
end

local function test_a_union_of_records_without_a_tag_names_why_the_closest_field_fails()
  local same = only(TAGS .. "local enum DK \"a\" end\nlocal record D\n  kind: DK\nend\nlocal type U = A | D\n")
  assert(same.code == "untagged_union" and has(same.msg, "have `kind` = \"a\""), same.msg)
  local none = only("local record A\n  n: integer\nend\nlocal record B\n  m: integer\nend\nlocal type U = A | B\n")
  assert(has(none.msg, "they share no field"), none.msg)
  local mutable = only("local enum AK \"a\" end\nlocal enum BK \"b\" end\nlocal record A\n  mut kind: AK\nend\n" ..
      "local record B\n  kind: BK\nend\nlocal type U = A | B\n")
  assert(has(mutable.msg, "`A.kind` is not a fixed field of an enum with one value"), mutable.msg)
  local many = only("local enum AK \"a\" \"b\" end\nlocal enum BK \"c\" end\nlocal record A\n  kind: AK\nend\n" ..
      "local record B\n  kind: BK\nend\nlocal type U = A | B\n")
  assert(has(many.msg, "`A.kind` is not a fixed field"), many.msg)
end

local function test_a_union_with_one_record_or_of_classes_and_primitives_needs_no_tag()
  local source = "local record A\n  n: integer\nend\nlocal class C\n  n: integer\nend\nlocal class D\n  n: integer\nend\n" ..
    "local type U = A | string\nlocal type V = C | D\nlocal type W = A | C | nil\n"
  assert(#errors_of(source) == 0)
end

-- dense arrays and keys -----------------------------------------------------------------------

local function test_an_array_or_a_map_value_that_may_be_nil_is_invalid_and_reported_once()
  local program = fresh()
  local result = Programs.lower(program, "t", "local a: {{string?}}\nlocal m: {string: integer?}\nlocal p: {integer}\nlocal q: mut {nil}\n")
  local codes = Programs.codes(result.lowered)
  assert(codes == "array_of_optional array_of_optional array_of_optional", codes)
  local invalid = 0
  for _, t in pairs(result.lowered.types) do
    if t.tag == "invalid" then
      invalid = invalid + 1
    end
  end
  assert(invalid >= 3)
  local e = result.lowered.errors[2]
  assert(has(e.msg, "the values of `{string: integer?}` may be nil, and `m[k] = nil` deletes the key"), e.msg)
  assert(has(e.fix, "write `{string: integer}`"), e.fix)
end

local function test_the_array_part_of_a_record_is_dense_too()
  local e = only("local record R is {string?}\nend\n")
  assert(e.code == "array_of_optional")
end

local function test_an_instance_of_a_generic_declaration_or_alias_that_makes_a_hole_is_refused()
  local base = "local record List<T>\n  items: {T}\nend\nlocal record Wrapper<U>\n  inner: List<U>\nend\n" ..
    "local type Row<V> = {V}\nlocal record Free<W>\n  w: W\nend\n"
  assert(#errors_of(base .. "local a: List<string>\nlocal b: Wrapper<integer>\nlocal c: Free<string?>\nlocal d: Row<integer>\n") == 0)
  local list = only(base .. "local a: List<string?>\n")
  assert(list.code == "array_of_optional" and has(list.msg, "`List` holds its type parameter 1 in an array or as the value of a map, so `string?` would make elements that may be nil"), list.msg)
  local through = only(base .. "local b: Wrapper<integer?>\n")
  assert(through.code == "array_of_optional" and has(through.msg, "`Wrapper` holds"), through.msg)
  local alias = only(base .. "local d: Row<string?>\n")
  assert(alias.code == "array_of_optional" and has(alias.msg, "`Row` holds"), alias.msg)
  -- inside a generic body the parameter may be anything: the instance is where it is checked
  assert(#errors_of(base .. "local function f<X>(l: List<X>)\nend\n") == 0)
end

local function test_a_key_is_an_integer_string_boolean_enum_or_a_declaration_never_number_any_or_an_optional()
  local ok = "local enum E \"a\" end\nlocal record R\nend\nlocal interface I\nend\nlocal class C\nend\n" ..
    "local a: {integer: R}\nlocal b: {string: R}\nlocal c: {boolean: R}\nlocal d: {E: R}\nlocal e: {R: R}\nlocal f: {I: R}\nlocal g: {C: R}\n"
  assert(#errors_of(ok) == 0)
  local bad = errors_of("local a: {number: R}\nlocal b: {any: integer}\nlocal c: {string?: integer}\nlocal d: {{integer}: integer}\n" ..
      "local e: {function(): integer: integer}\nlocal f: {true: integer}\nlocal g: {nil: integer}\n")
  local codes: {string} = {}
  for i, e in ipairs(bad) do
    codes[i] = e.code
  end
  -- the first has an unknown R besides
  assert(table.concat(codes, " ") == "float_key key_type key_type key_type key_type key_type key_type", table.concat(codes, " "))
  assert(has(bad[2].msg, "not keyed by `any`") and has(bad[3].msg, "an optional") and has(bad[4].msg, "a collection") and
      has(bad[5].msg, "a function"), bad[2].msg)
  local instance = only("local record Set<K>\n  keys: {K: boolean}\nend\nlocal s: Set<number>\n")
  assert(instance.code == "float_key" and has(instance.msg, "`Set` keys a map by its type parameter 1"), instance.msg)
end

-- names and counts -----------------------------------------------------------------------------

local function test_a_function_typed_field_of_a_declaration_file_may_repeat_as_an_overload_and_no_other_may()
  local program = fresh()
  local ok = Programs.lower(program, "t", "global record io\n  read: function(io): string\n  read: function(io, integer): string\nend\n", "decl")
  assert(#ok.lowered.errors == 0, Programs.codes(ok.lowered))
  assert(#body_of(program, "t", "io").fields == 2)
  local bad = errors_of("global record io\n  n: integer\n  n: integer\n  mut f: function()\n  mut f: function()\nend\n", "decl")
  assert(#bad == 2 and bad[1].code == "repeated_field" and has(bad[1].msg, "only a function-typed field of a declaration file"), bad[1] and bad[1].msg or "")
  assert(bad[1].other ~= nil)
  -- in a program none may
  local text = errors_of("local record R\n  f: function()\n  f: function()\nend\n")
  assert(#text == 1 and text[1].code == "repeated_field")
end

local function test_the_count_of_type_arguments_is_held_for_declarations_aliases_primitives_and_parameters()
  local base = "local record R<T>\nend\nlocal type A<T, U> = {T}\nlocal type B = integer\n"
  local function one(use: string): Declarations.Error
    return only(base .. "local x: " .. use .. "\n")
  end
  assert(has(one("R<integer, string>").msg, "`R` takes 1 type argument, not 2"))
  assert(has(one("A<integer>").msg, "`A` takes 2 type arguments, not 1"))
  assert(has(one("B<integer>").msg, "`B` takes no type arguments, not 1") and has(one("B<integer>").fix, "remove the type arguments"))
  assert(has(one("integer<string>").msg, "`integer` takes no type arguments"))
  assert(has(only("local function f<T>(x: T<integer>)\nend\n").msg, "the type parameter `T` takes no type arguments"))
end

local function test_a_type_nested_past_the_store_depth_through_aliases_is_invalid_and_reported()
  local out: {string} = { "local type A0 = integer\n" }
  for i = 1, 1005 do
    out[#out + 1] = "local type A" .. i .. " = {A" .. (i - 1) .. "}\n"
  end
  -- The aliases lower where first used, so the chain nests as deep as the use is far: a use of A1005 first
  -- recurses through all of them.
  out[#out + 1] = "local x: A1005\n"
  local e = errors_of(table.concat(out))
  assert(#e >= 1)
  local deep = false
  for _, err in ipairs(e) do
    if err.code == "type_too_deep" then
      deep = true
    end
  end
  assert(deep, e[1].code .. " " .. e[1].msg)
end

local function test_a_chain_of_aliases_longer_than_the_nesting_limit_is_reported_and_not_unfolded_without_end()
  -- declared last first, so that lowering the first recurses through all
  local out: {string} = {}
  for i = 400, 1, -1 do
    out[#out + 1] = "local type A" .. i .. " = A" .. (i - 1) .. "\n"
  end
  out[#out + 1] = "local type A0 = integer\nlocal x: A400\n"
  local e = errors_of(table.concat(out))
  assert(#e >= 1 and e[1].code == "type_too_deep" and has(e[1].msg, "a chain of more than 200 aliases"), e[1] and e[1].msg or "")
end

local function test_aliases_may_be_declared_after_their_use_and_mutual_aliases_are_a_cycle()
  local program = fresh()
  local result = Programs.lower(program, "t", "local type Early = {Later}\nlocal type Later = {integer}\nlocal x: Early\n")
  assert(#result.lowered.errors == 0 and #result.scope_errors == 0, Programs.codes(result.lowered))
  local mutual = errors_of("local type A = B\nlocal type B = A\n")
  assert(#mutual >= 1 and mutual[1].code == "alias_cycle", mutual[1] and mutual[1].code or "none")
end

local function test_a_bound_is_one_interface_used_with_no_arguments()
  assert(#errors_of("local interface Ordered\nend\nlocal function max<T is Ordered>(a: T, b: T): T\n  return a\nend\n") == 0)
  -- a generic interface used bare is the arguments' mistake, and the bound is dropped
  local args = only("local interface G<T>\nend\nlocal function f<T is G>(a: T)\nend\n")
  assert(args.code == "type_arguments" and has(args.msg, "`G` takes 1 type argument, not 0"), args.msg)
end

local function test_a_type_parameter_of_the_code_around_a_use_is_not_held_to_a_bound_until_it_is_instantiated()
  local head = "local interface Named\n  name: string\nend\nlocal record Box<T is Named>\n  value: T\nend\n"
  assert(#errors_of(head .. "local function f<U>(b: Box<U>)\nend\n") == 0)
  local unmet = only(head .. "local record Plain\n  name: string\nend\nlocal function f<U>(b: Box<Plain>, u: U)\nend\n")
  assert(unmet.code == "bound_not_met", unmet.code)
end

-- modules ------------------------------------------------------------------------------------

local function test_a_module_names_the_types_of_one_it_imports_and_what_it_exports()
  local program = fresh()
  assert(#Programs.lower(program, "cosmic.stream", Programs.stream_source).lowered.errors == 0)
  local source = [[
local type Stream = require("cosmic.stream")
local type Reader = Stream.Reader
local a: Stream.Reader
local b: Reader
local c: Stream
local d: {Stream.Reader}
]]
  local result = Programs.lower(program, "user", source)
  assert(#result.lowered.errors == 0, Programs.codes(result.lowered))
  local reader = program.store:find("cosmic.stream", "Stream.Reader")
  assert(reader ~= nil and reader.kind == "interface")
  local store = program.store
  assert(annotation(result, 3) == store:named(reader))
  assert(annotation(result, 4) == store:named(reader))
  local stream = store:find("cosmic.stream", "Stream")
  assert(stream ~= nil and annotation(result, 5) == store:named(stream))
  local export = program.modules["cosmic.stream"].export
  assert(export ~= nil and export.decl == stream)
end

local function test_a_name_the_imported_module_lacks_and_a_module_that_returns_no_declaration_are_member_missing()
  local program = fresh()
  Programs.lower(program, "cosmic.stream", Programs.stream_source)
  Programs.lower(program, "plain", "local function f()\nend\nreturn f\n")
  local source = "local type Stream = require(\"cosmic.stream\")\nlocal type Plain = require(\"plain\")\n" ..
    "local type Gone = require(\"gone\")\nlocal a: Stream.Writer\nlocal b: Plain\nlocal c: Gone\n"
  local result = Programs.lower(program, "user", source).lowered
  assert(Programs.codes(result) == "member_missing member_missing member_missing", Programs.codes(result))
  assert(has(result.errors[1].msg, "`Stream` declares no type `Writer`"))
  assert(has(result.errors[2].msg, "the module `plain` returns no declaration"))
  assert(has(result.errors[3].msg, "the module `gone` that `Gone` imports is not known"))
end

local function test_a_provider_declares_a_module_not_yet_lowered_and_a_check_waits_for_its_body()
  local program = fresh()
  local b = "local record B\n  interface I\n    n: integer\n  end\nend\nreturn B\n"
  program.provider = function(self: Declarations.Program, module: string): boolean
    if module ~= "b" then
      return false
    end
    Programs.declare(self, "b", b)
    return true
  end
  local a = "local type B = require(\"b\")\nlocal class C is B.I\nend\n"
  local early = Programs.lower(program, "a", a).lowered
  assert(#early.errors == 0 and program:unsettled() == 1, Programs.codes(early))
  assert(#Programs.lower(program, "b", b).lowered.errors == 0)
  assert(program:unsettled() == 0)
  local errors = program:errors("a")
  assert(#errors == 1 and errors[1].code == "interface_disagrees" and has(errors[1].msg, "has no field or method `n`"))
end

local function test_an_alias_of_a_module_that_is_declared_and_not_lowered_is_unavailable()
  local program = fresh()
  program.provider = function(self: Declarations.Program, module: string): boolean
    if module ~= "b" then
      return false
    end
    Programs.declare(self, "b", "local type K = {integer}\nlocal record R\nend\nreturn R\n")
    return true
  end
  local result = Programs.lower(program, "a", "local type B = require(\"b\")\nlocal r: B\n")
  assert(#result.lowered.errors == 0)
  local entry = program.entries["b\0K"]
  assert(entry ~= nil)
  local alias = entry.alias
  assert(alias ~= nil and alias.state == "unavailable")
end

local function test_a_name_declared_twice_or_in_a_function_body_is_its_own_declaration()
  local program = fresh()
  local source = [[
local record Row
  a: integer
end
local function f()
  local record Row
    b: string
  end
  local x: Row
end
local record Row
  c: boolean
end
local y: Row
]]
  local result = Programs.lower(program, "t", source)
  assert(#result.lowered.errors == 0, Programs.codes(result.lowered))
  local rows: {Types.Decl} = {}
  for _, d in ipairs(program.store:declarations()) do
    if d.name == "Row" then
      rows[#rows + 1] = d
    end
  end
  assert(#rows == 3, #rows)
  local modules: {string: boolean} = {}
  for _, d in ipairs(rows) do
    modules[d.module] = true
  end
  assert(modules["t"], "the first is the module's own")
  -- the second declaration in the function's body is not reachable from outside
  local count = 0
  for m in pairs(modules) do
    if m:find("@", 1, true) ~= nil then
      count = count + 1
    end
  end
  assert(count == 2)
end

local function test_a_declaration_file_declares_globals_and_userdata_methods()
  local program = fresh()
  local source = [[
global record FILE
  userdata
  close: function(FILE): boolean
  name: string
  enum Mode "r" "w" end
  open: function(string, Mode): FILE
end
]]
  local result = Programs.lower(program, "decl", source, "decl")
  assert(#result.lowered.errors == 0, Programs.codes(result.lowered))
  local file = program.store:find("decl", "FILE")
  assert(file ~= nil and file.kind == "userdata")
  local body = body_of(program, "decl", "FILE")
  assert(#body.methods == 1 and body.methods[1].name == "close" and #body.fields == 2)
  assert(program.globals["FILE"] ~= nil and program:scope_globals()["FILE"].space == "both")
  local user = Programs.lower(program, "user", "local f: FILE\nlocal m: FILE.Mode\nlocal g: Nope\n")
  assert(#user.lowered.errors == 0 and #user.scope_errors == 1)
  assert(annotation(user, 2).tag == "named")
end

-- annotations ---------------------------------------------------------------------------------

local function test_the_annotations_of_a_body_are_lowered_with_the_type_parameters_in_scope()
  local program = fresh()
  local source = [[
local function pair<A, B>(a: A, b: B): A
  local both: {A}
  local f: function<C>(C, A): B
  local ok = a is string
  return a
end
]]
  local result = Programs.lower(program, "t", source)
  assert(#result.lowered.errors == 0, Programs.codes(result.lowered))
  local fn = result.chunk.body.stats[1]
  assert(fn is Ast.LocalFunction)
  local types = result.lowered.types
  local names: {{string}} = { { "A", "B" } }
  local param = fn.fn.params[1].type
  assert(param ~= nil and Types.display(types[param.id], names) == "A")
  local both = fn.fn.body.stats[1]
  assert(both is Ast.Local)
  assert(Types.display(types[both.types[1].id], names) == "{A}")
  local f = fn.fn.body.stats[2]
  assert(f is Ast.Local)
  -- the function's own parameter is the nearest binder's, displayed under a name of its own
  assert(Types.display(types[f.types[1].id], names) == "function<T_1>(T_1, A): B", Types.display(types[f.types[1].id], names))
  assert(Types.display(types[fn.fn.id]) == "function<T, U>(T, U): T", Types.display(types[fn.fn.id]))
end

local function test_a_narrowing_return_names_the_position_of_its_parameter_and_a_method_signature_is_a_type()
  local program = fresh()
  local source = [[
local record Reader
end
local class C
  function is_reader(self, v: any): boolean
    return true
  end
end
local x: function(v: any): v is Reader
local y: function(a: string, b: any): asserts b is Reader
]]
  local result = Programs.lower(program, "t", source)
  assert(#result.lowered.errors == 0, Programs.codes(result.lowered))
  local xt, yt = annotation(result, 3), annotation(result, 4)
  assert(xt is Types.Fn and yt is Types.Fn)
  local xn, yn = xt.rets[1].narrows, yt.rets[1].narrows
  assert(xn ~= nil and xn.param == 1 and not xn.asserts)
  assert(yn ~= nil and yn.param == 2 and yn.asserts)
  local methods = body_of(program, "t", "C").methods
  assert(#methods == 1 and Types.display(methods[1].type) == "function(C, any): boolean")
end

local function test_a_module_is_lowered_once_and_its_declarations_are_the_stores()
  local program = fresh()
  Programs.lower(program, "t", "local record R\nend\n")
  local ok, why = pcall(function()
    Programs.lower(program, "t", "local record R\nend\n")
  end)
  assert(not ok and tostring(why):find("was lowered already", 1, true) ~= nil, tostring(why))
end

-- function statements, global values and the library records of primitives ------------------------------

local function test_a_statement_that_defines_a_function_of_a_record_gives_the_declaration_that_field_unless_it_declares_one()
  local program = fresh()
  local source = [[
local record R
  declared: function(integer): integer
  n: integer
end
function R.declared(n: integer): integer
  return n
end
function R.defined<T>(a: T, b?: string): {T}
  return {}
end
function R.untyped(a)
end
function R.defined(n: integer)
end
]]
  local result = Programs.lower(program, "t", source)
  assert(Programs.codes(result.lowered) == "", Programs.codes(result.lowered))
  local body = body_of(program, "t", "R")
  local names: {string} = {}
  for _, f in ipairs(body.fields) do
    names[#names + 1] = f.name
  end
  assert(table.concat(names, " ") == "declared n", table.concat(names, " "))
  local decl = program.store:find("t", "R")
  assert(decl ~= nil)
  local statics = program.statics[decl]
  assert(statics ~= nil and statics.defined and statics.untyped and not statics.declared and not statics.n)
  assert(Types.display(statics.defined.type) == "function<T>(T, p2?: string): {T}", Types.display(statics.defined.type))
  assert(statics.untyped.type.tag == "invalid")
  -- the statement of a declared field is lowered once, as any function is
  local twice = 0
  for _, e in ipairs(result.lowered.errors) do
    twice = twice + (e.code == "repeated_field" and 1 or 0)
  end
  assert(twice == 0)
end

local function test_a_function_statement_of_a_record_declared_in_a_function_or_on_a_longer_path_gives_no_field()
  local program = fresh()
  local source = [[
local record Outer
  record Inner
    n: integer
  end
end
function Outer.Inner.make()
end
local function f()
  local record Local
    n: integer
  end
  function Local.make()
  end
end
]]
  local result = Programs.lower(program, "t", source)
  assert(Programs.codes(result.lowered) == "", Programs.codes(result.lowered))
  assert(#body_of(program, "t", "Outer.Inner").fields == 1)
  local decl = program.store:find("t", "Outer.Inner")
  assert(decl ~= nil and program.statics[decl] == nil)
end

local function test_a_declaration_file_gives_the_types_of_its_global_values()
  local program = fresh()
  local source = [[
local record Lib
  print: function(...: any)
  tonumber: function(any): number?
  tonumber: function(any, integer): integer?
  arg: {string}
end
global print <const> = Lib.print
global tonumber <const> = Lib.tonumber
global arg <const> = Lib.arg
global version: string
global missing <const> = Lib.missing
]]
  local result = Programs.lower(program, "t", source, "decl")
  assert(Programs.codes(result.lowered) == "", Programs.codes(result.lowered))
  local values = program.values
  assert(#values.print == 1 and Types.display(values.print[1]) == "function(...: any)")
  assert(#values.tonumber == 2 and Types.display(values.tonumber[2]) == "function(any, integer): integer?")
  assert(Types.display(values.arg[1]) == "{string}" and Types.display(values.version[1]) == "string")
  assert(values.missing == nil)
end

local function test_a_global_record_named_for_a_primitive_is_a_value_and_the_type_stays_the_primitive()
  local program = fresh()
  local library = Programs.lower(program, "std", "global record string\n  upper: function(string): string\nend\n", "decl")
  assert(Programs.codes(library.lowered) == "", Programs.codes(library.lowered))
  local entry = program.globals["string"]
  local decl = entry ~= nil and entry.decl or nil
  assert(decl ~= nil and decl.name == "std.string")
  local user = Programs.lower(program, "user", "local s: string\n")
  assert(#user.lowered.errors == 0)
  assert(annotation(user, 1) == program.store.string)
end

local function test_a_lowered_module_names_the_declaration_each_binding_stands_for()
  local program = fresh()
  local result = Programs.lower(program, "t", "local record R\nend\nlocal type A = {R}\nlocal enum E \"a\" end\n")
  local entries = result.lowered.entries
  local count = 0
  for _, entry in pairs(entries) do
    count = count + 1
    assert(entry.decl ~= nil or entry.alias ~= nil)
  end
  assert(count == 3)
end
