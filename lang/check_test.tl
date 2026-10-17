--- Tests of [`lang.check`]: a case for each code it reports, with the place, message and fix; programs that stand;
--- the types of names; and the programs the fork accepts that [`build/teal_test.tl`] pins and the plan refuses, as
--- the questions of expressions they are.
local Check = require("lang.check")
local Codes = require("lang.check_codes")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local function has(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

--- A case for each code: a source with one mistake, and what its message and fix say.
local record Case
  code: Codes.Code
  source: string
  msg: string
  fix: string
  --- The modules the source requires, by name.
  modules?: {string: string}
  --- The codes it has, when it has more than its own.
  codes?: string
  --- The line and column of the error.
  at?: {integer}
end

local RECORD <const> = "local record R\n  name: string\n  n: integer\nend\n"
local FIND <const> = "local function find(): string?\n  return nil\nend\n"

local CASES <const>: {Case} = {
  {
    code = "not_assignable", source = "local n: integer = 3.5\n", at = { 1, 20 },
    msg = "`3.5` is `number`, where `integer` is wanted as the value of `n`",
    fix = "convert with `math.tointeger(3.5)` or `math.floor(3.5)`, or declare what takes it `number`",
  },
  {
    code = "not_assignable", source = "local record A\nend\nlocal record B\nend\nlocal a: A = {}\nlocal b: B = a\n",
    msg = "`a` is `A`, where `B` is wanted as the value of `b`", fix = "pass a value of type `B`, or change the declaration to `A`",
  },
  {
    code = "nil_not_allowed", source = FIND .. "local s: string = find()\n", at = { 4, 19 },
    msg = "`find()` is `string?`, so it may be nil, where `string` is wanted as the value of `s`",
    fix = "take the value with `local v = assert(find())`, or test it first",
  },
  {
    code = "nil_not_allowed", source = "local s: string = nil\n",
    msg = "nil is given as the value of `s`, where `string` is wanted", fix = "declare what takes it `string?`",
  },
  {
    code = "index_may_be_nil", source = "local xs: {string} = {}\nlocal s: string = xs[1]\n", at = { 2, 19 },
    msg = "`xs[1]` is `string?` (an index read may be nil), where `string` is wanted",
    fix = "iterate with `for _, v in ipairs(xs)`",
  },
  {
    code = "view_as_mut",
    source = "local function add(xs: mut {string}) end\nlocal v: {string} = {}\nadd(v)\n",
    msg = "`v` is `{string}`, where `mut {string}` is wanted as argument 1 of `add`",
    fix = "declare `v` `mut {string}` where it is made or received",
  },
  {
    code = "invariant_mut",
    source = "local function f(xs: mut {number}) end\nlocal v: mut {integer} = {}\nf(v)\n",
    msg = "`integer` is not `number`", fix = "pass a view, or declare the receiver's type `mut {integer}` as the argument has it",
  },
  {
    code = "record_as_map",
    source = RECORD .. "local function f(m: {string: integer}) end\nlocal r: R = { name = \"a\", n = 1 }\nf(r)\n",
    msg = "`r` is `R`, where `{string: integer}` is wanted as argument 1 of `f`: a record is not a map",
    fix = "declare a map `{K: V}` for the data that is keyed",
  },
  {
    code = "any_use", source = "local function f(v: any)\n  local n: integer = v\nend\n",
    msg = "`v` is untrusted data (`any`), where `integer` is wanted as the value of `n`",
    fix = "validate it with a [`cosmic.shape`] validator",
  },
  {
    code = "any_use", source = "local function f(v: any): integer\n  return #v\nend\n",
    msg = "`v` is untrusted data (`any`), and `#` takes a string or an array", fix = "test its tag",
  },
  {
    code = "view_written", source = "local function f(xs: {integer})\n  xs[#xs + 1] = 1\nend\n", at = { 2, 3 },
    msg = "`xs` is a view `{integer}`, so `xs[#xs + 1]` cannot be assigned",
    fix = "declare `xs` `mut {integer}` where it is made or received",
  },
  {
    code = "field_fixed", source = RECORD .. "local r: R = { name = \"a\", n = 1 }\nr.n = 2\n", at = { 6, 1 },
    msg = "`R.n` is fixed: it is not declared `mut`", fix = "declare `mut n: integer` in `R`, or make a new `R`",
  },
  {
    code = "array_hole", source = "local xs: mut {integer} = {}\nxs[1] = 2\n", at = { 2, 1 },
    msg = "`xs[1]` may leave a hole in the array `xs`", fix = "append with `xs[#xs + 1] = v` or `table.insert`",
  },
  {
    code = "float_key", source = "local xs: mut {integer} = {}\nlocal i: number = 1.5\nlocal v = xs[i]\n", at = { 3, 14 },
    msg = "`i` is a `number`, and `xs` is keyed by `integer`", fix = "convert it: `math.tointeger(i)` or `math.floor(i)`",
    codes = "float_key",
  },
  {
    code = "field_unknown", source = RECORD .. "local r: R = { name = \"a\", n = 1 }\nlocal x = r.nam\n",
    msg = "`R` has no field `nam`, nearest `name`", fix = "write `name`, or declare `nam` in `R`",
  },
  {
    code = "map_field", source = "local m: {string: integer} = {}\nlocal x = m.a\n",
    msg = "`m.a` reads a field of a map, `{string: integer}`, which is read by a key",
    fix = "write `[\"a\"]` after the map, or declare a record for the fields",
  },
  {
    code = "record_index",
    source = RECORD .. "local r: R = { name = \"a\", n = 1 }\nlocal k: string = \"name\"\nlocal x = r[k]\n",
    msg = "`k` is `string`, which names no field of `R`: a record is not a map",
    fix = "write the field (`r.field`), or index a `{K: V}`",
  },
  {
    code = "not_indexable", source = "local n = 1\nlocal x = n.a\n",
    msg = "`n.a` reads a field of `integer`, which has none", fix = "read a field of a record, class or interface",
  },
  {
    code = "not_callable", source = "local n = 1\nn()\n",
    msg = "`n` is `integer`, which is not a function", fix = "call a function",
  },
  {
    code = "overload_value", source = "local f = string.gsub\n",
    msg = "`string.gsub` has several overloads, which are no value: only a call picks one",
    fix = "write a function of the one you mean: `function(...) return string.gsub(...) end`",
  },
  {
    code = "arity", source = "local function f(a: integer)\nend\nf(1, 2)\n", at = { 3, 1 },
    msg = "`f` takes 1 argument, but 2 are given", fix = "remove the extra argument",
  },
  {
    code = "arity", source = "local function f(a: integer, b?: string)\nend\nf()\n",
    msg = "`f` takes 1 to 2 arguments, but 0 are given", fix = "pass the missing argument 1, `integer`",
  },
  {
    code = "overload_none", source = "local x = string.gsub(\"a\", 1, 2)\n",
    msg = "no overload of `string.gsub` takes the arguments (string, integer, integer)",
    fix = "pass arguments one overload accepts, in its order: function(string, string, string, p4?: integer)",
  },
  {
    code = "return_arity", source = "local function f(): integer, string\n  return 1\nend\n", at = { 2, 3 },
    msg = "this returns 1 value, where the function answers 2 values", fix = "return 2 values",
  },
  {
    code = "return_unexpected", source = "local function f()\n  return 1\nend\n",
    msg = "this function returns nothing, and this returns 1 value", fix = "declare the return list: `function f(): T`",
  },
  {
    code = "return_unexpected", source = "local function f(): never\n  return\nend\n",
    msg = "this function is declared `never` and cannot return", fix = "end it with `error(...)`",
  },
  {
    code = "no_value", source = "local function f()\nend\nlocal x = f() .. \"a\"\n",
    msg = "`f()` answers nothing, so it has no value here", fix = "use the call as a statement",
  },
  {
    code = "alternatives_as_value",
    source = "local f: function(): (true, integer) | (false, string)\nlocal x = f()\n",
    msg = "`f()` answers one of 2 lists of values, which is no value", fix = "match the call: `match f() do",
  },
  {
    code = "value_count", source = "local a, b = 1\n", at = { 1, 1 },
    msg = "this gives 1 value to 2 names, so the last name is nil", fix = "give 2 values",
  },
  {
    code = "vararg_outside", source = "local function f()\n  local x = ...\nend\n",
    msg = "`...` is used in a function that has no rest parameter", fix = "declare the rest parameter `...: T`",
  },
  {
    code = "param_untyped", source = "local function f(a)\nend\n", at = { 1, 18 },
    msg = "the parameter `a` of `f` has no type, and no function type is expected here to give it one",
    fix = "write the type: `a: T`",
  },
  {
    code = "local_untyped", source = "local x\n", at = { 1, 7 },
    msg = "`x` has no type and no value", fix = "write its type: `local x: T` (`T?` if it may stay unset)",
  },
  {
    code = "condition_type", source = "local s = \"a\"\nif s then\nend\n", at = { 2, 4 },
    msg = "`s` is `string`, which is no boolean or optional, so it is no condition", fix = "write the test: `s ~= \"\"`",
  },
  {
    code = "condition_type", source = "local b: boolean? = nil\nwhile b do\nend\n",
    msg = "`b` is `boolean?`: nil and false would not be told apart", fix = "write the test: `b == true` or `b == nil`",
  },
  {
    code = "or_mix", source = "local b = true\nlocal x = b or 1\n",
    msg = "`b` is a boolean and `1` is `integer`", fix = "write the test: `if b then ... else ... end`",
  },
  {
    code = "or_mix", source = FIND .. "local x = find() or 1\n",
    msg = "`find()` is `string?` and `1` is `integer`, which have no common type for the default",
    fix = "give a default of `string`",
  },
  {
    code = "and_ternary", source = "local c = true\nlocal x = c and 1 or 2\n", at = { 2, 11 },
    msg = "`c and 1 or 2` is a ternary: it answers `2` when `1` is false or nil",
    fix = "use the `if` expression: `if c then 1 else 2 end`",
  },
  {
    code = "concat_type", source = "local n = 1\nlocal s = \"a\" .. n\n", at = { 2, 18 },
    msg = "`n` is `integer`, and `..` takes strings", fix = "write `tostring(n)` or `string.format(\"%d\", n)`",
  },
  {
    code = "operand_type", source = "local s = \"a\"\nlocal n = s + 1\n",
    msg = "`s` is `string`, and `+` takes numbers", fix = "convert it with `tonumber(s)`",
  },
  {
    code = "compare_disjoint", source = "local n = 1\nif n == \"a\" then\nend\n",
    msg = "`n` is `integer` and `\"a\"` is `string`, which share no value: the test is never true",
    fix = "compare values of one type, or remove the test",
  },
  {
    code = "generic_op", source = "local function lt<T>(a: T, b: T): boolean\n  return a < b\nend\n",
    msg = "`a` is the type parameter `T`, which ranges over every type, and `<` takes numbers or strings",
    fix = "bound the type parameter by an interface that declares the operation (`T is Ordered`)",
  },
  {
    code = "cast_refused", source = "local x = 1\nlocal y = x as number\n",
    msg = "`as` is not in the language: `x as number` changes a type by no check", fix = "validate the value with a [`cosmic.shape`] validator",
  },
  {
    code = "is_on_record", source = RECORD .. "local function f(v: R | string)\n  if v is R then\n  end\nend\n",
    msg = "`is R` cannot be told by a run-time tag: a record leaves nothing to test",
    fix = "test a tag (`x.kind == \"...\"`), declare a class",
  },
  {
    code = "is_disjoint", source = "local function f(n: integer): boolean\n  return n is string\nend\n", at = { 2, 10 },
    msg = "`n is string` is always false: `n` is `integer`, and no value of it is `string`",
    fix = "this test is always false: remove it and the branch it guards, or test a type that `n` can have (`integer`)",
  },
  {
    code = "interface_method_value",
    source = "local interface Sized\n  size: function(self: Sized): integer\nend\nlocal function f(s: Sized)\n  local g = s.size\nend\n",
    at = { 5, 13 }, msg = "`s.size` reads the method `size` of the interface `Sized` as a value",
    fix = "call it as `s:size(...)`",
  },
  {
    code = "declaration_value", source = "local class C\n  n: integer\nend\nlocal c: C = C\n",
    msg = "`C` is `C (declaration)`, the table of the functions of `C`, where a value of `C` is wanted as the value of `c`",
    fix = "make a value with a table literal typed as the type (`local v: C = { ... }`)",
  },
  {
    code = "class_scope", source = "local type K = require(\"other\")\nlocal k: K = { n = 1 }\n", at = { 2, 14 },
    modules = { other = "local class K\n  n: integer\nend\nreturn K\n" },
    msg = "this literal makes a value of `K`, a class of the module `other`, whose metatable only that module reaches",
    fix = "make the value in `other` with a function of the class (`function K.new(...): K`)",
  },
  {
    code = "close_not_closable", source = RECORD .. "local r: R = { name = \"a\", n = 1 }\nlocal c <close>: R = r\n",
    msg = "`c` is a `<close>` local of `R`, and `R` is not a class",
    fix = "hold a class that declares `function __close(self)` (or nil) in `c`",
  },
  {
    code = "setmetatable_call", source = "local t = setmetatable({}, {})\n", at = { 1, 11 },
    msg = "a program has no `setmetatable`: the metatable of a value is the compiler's",
    fix = "declare a `class` with the methods and write the value as a table literal typed as the class",
  },
  {
    code = "enum_member", source = "local enum E \"a\" \"b\" end\nlocal e: E = \"c\"\n", at = { 2, 14 },
    msg = "`\"c\"` is not a member of `E`", fix = "write `\"a\"` or `\"b\"`",
  },
  {
    code = "literal_missing", source = RECORD .. "local r: R = { name = \"a\" }\n", at = { 5, 14 },
    msg = "this literal of `R` leaves out `n`", fix = "add `n` to the literal",
  },
  {
    code = "literal_unknown", source = RECORD .. "local r: R = { name = \"a\", n = 1, nam = \"b\" }\n",
    msg = "`R` has no field `nam`, nearest `name`", fix = "write `name`, or declare `nam` in `R`",
  },
  {
    code = "literal_repeated", source = RECORD .. "local r: R = { name = \"a\", n = 1, name = \"b\" }\n",
    msg = "the field `name` is written twice", fix = "remove the second `name`",
  },
  {
    code = "literal_needs_type", source = "local t = {}\n", at = { 1, 11 },
    msg = "this literal has no items and no type to make it from", fix = "declare the type: `local name: mut {T} = {}`",
  },
  {
    code = "literal_ambiguous",
    source = "local enum AK \"a\" end\nlocal enum BK \"b\" end\nlocal record A\n  kind: AK\n  n: integer\nend\n" ..
      "local record B\n  kind: BK\n  n: integer\nend\nlocal x: A | B = { n = 1 }\n",
    msg = "this literal could be any of `A` or `B`", fix = "give the tag field of the member it is",
  },
  {
    code = "literal_shape", source = "local interface I\n  n: integer\nend\nlocal x: I = { n = 1 }\n",
    msg = "a table literal cannot make `I`, an interface", fix = "make the value with a class that lists `I`",
  },
  {
    code = "arms_differ", source = "local t = { 1, \"a\" }\n",
    msg = "the elements of this literal have no common type: `integer` or `string`",
    fix = "type the literal: `local name: {integer} = ...`, or make the elements one type",
  },
  {
    code = "array_of_optional", source = "local t = { 1, nil }\n",
    msg = "an element of this literal may be nil, and an array is dense", fix = "use a map `{integer: T}` for sparse data",
  },
  {
    code = "require_unknown", source = "local x = require(\"nope\")\n",
    msg = "the project has no module `nope`", fix = "require a module of the project",
  },
  {
    code = "export_not_declared", source = "local t = { 1 }\nreturn t\n", at = { 2, 1 },
    msg = "this module returns `t`, which no declaration describes", fix = "return a record, class, interface or enum of the module",
  },
  {
    code = "unchecked_generic", source = "local xs: mut {integer} = {}\ntable.insert(xs, 1)\n", at = { 2, 1 },
    msg = "this call of the generic function `table.insert`, which the checker types in a later piece",
    fix = "none yet: the generics piece types a call of a generic function",
  },
  {
    code = "unchecked_protected", source = "local ok = pcall(print)\n",
    msg = "a protected call `pcall`", fix = "none yet: the piece of `match` and protected calls types `pcall` and `xpcall`",
  },
  {
    code = "unchecked_coroutine", source = "local c = coroutine.create(print)\n",
    msg = "a coroutine function `coroutine.create`", fix = "none yet: the same piece types `coroutine.*`",
  },
  {
    code = "unchecked_match",
    source = "local f: function(): (true, integer) | (false, string)\nmatch f() do\n  | (true, v) then\n  | (false, why) then\nend\n",
    msg = "a `match`, which the checker types in a later piece", fix = "none yet: the piece of `match` types the arms",
    codes = "unchecked_match",
  },
  {
    code = "unchecked_binding", source = "local sys = require(\"cosmic.sys\")\n", at = { 1, 13 },
    msg = "the module `cosmic.sys` is a binding of C that has no declarations",
    fix = "none yet: the bindings of C are typed once the checker reads them from declaration files",
  },
  {
    code = "unchecked_nested",
    source = "local function outer<T>(x: T)\n  local function inner<U>(y: U)\n  end\nend\n",
    msg = "this generic function is inside the code of another", fix = "none yet: the generics piece types a generic function inside another",
  },
}

local function test_each_case_has_its_error_with_place_message_and_fix()
  local seen: {string: boolean} = {}
  local problems: {string} = {}
  for i, case in ipairs(CASES) do
    local r = Programs.run(case.source, case.modules)
    local label = "case " .. i .. " " .. case.code
    seen[case.code] = true
    if #r.before > 0 then
      problems[#problems + 1] = label .. ": the source has " .. table.concat(r.before, " ")
    elseif Programs.codes(r) ~= (case.codes or case.code) then
      problems[#problems + 1] = label .. ": has " .. Programs.codes(r) .. (r.errors[1] ~= nil and " (" .. r.errors[1].msg .. ")" or "")
    else
      local e = r.errors[#r.errors]
      for _, each in ipairs(r.errors) do
        if each.code == case.code then
          e = each
        end
      end
      if not has(e.msg, case.msg) then
        problems[#problems + 1] = label .. ": msg " .. e.msg .. "\n    wanted " .. case.msg
      end
      if not has(e.fix, case.fix) then
        problems[#problems + 1] = label .. ": fix " .. e.fix .. "\n    wanted " .. case.fix
      end
      local at = case.at
      if at ~= nil and (e.y ~= at[1] or e.x ~= at[2]) then
        problems[#problems + 1] = label .. ": at " .. e.y .. ":" .. e.x .. ", wanted " .. at[1] .. ":" .. at[2]
      end
    end
  end
  assert(#problems == 0, table.concat(problems, "\n"))
  for _, code in ipairs(Check.codes) do
    assert(seen[code], code .. " has no case")
  end
end

local function test_every_code_has_a_row_with_a_rule_a_reason_and_a_fix_and_the_catalog_names_each_once()
  local owned: {string: boolean} = {}
  for _, row in ipairs(Check.catalog) do
    assert(not owned[row.code], row.code .. " is in the catalog twice")
    owned[row.code] = true
    assert(row.rule ~= "" and row.why ~= "" and row.fix ~= "")
  end
  for _, code in ipairs(Check.codes) do
    local row = Codes.row(code)
    assert(row ~= nil and row.code == code, code .. " has no row")
  end
  for code in pairs(owned) do
    local listed = false
    for _, each in ipairs(Check.codes) do
      listed = listed or tostring(each) == code
    end
    assert(listed, code .. " is in the catalog and not in the list of codes")
  end
end

local function test_the_codes_the_declarations_own_are_not_in_this_catalog()
  local owned: {Codes.Code} = { "float_key", "array_of_optional", "param_untyped" }
  for _, code in ipairs(owned) do
    for _, row in ipairs(Check.catalog) do
      assert(row.code ~= code, code .. " has its row in lang.declarations")
    end
    assert(Codes.row(code) ~= nil)
  end
end

-- programs that stand ------------------------------------------------------------------------------

--- Programs that follow the rules, each checked clean.
local STANDING <const>: {string: string} = {
  ["records and literals"] = [[
local enum Color "red" "green" end
local record Point
  x: number
  y: number
  color: Color
  mut label?: string
end
local record Line
  from: Point
  to: Point
  tags: mut {string}
end
local p: Point = { x = 1, y = 2.5, color = "red" }
local line: Line = { from = p, to = { x = 0, y = 0, color = "green", label = "o" }, tags = {} }
p.label = "start"
line.tags[#line.tags + 1] = "a"
local c: Color = if p.x > 1 then "red" else "green" end
]],
  ["arithmetic, concatenation and comparison"] = [[
local a: integer = 1
local b: number = 2.5
local sum = a + b
local whole: integer = a * 2 // 3 % 5
local ratio: number = a / 2
local power: number = a ^ 2
local bits: integer = (a & 3) | (a << 1) ~ a
local text: string = "n=" .. tostring(a) .. "!"
local less: boolean = a < b
local same: boolean = "a" < text
local neg: integer = -a
local length: integer = #text
local ok: boolean = not less and same or a == 1
]],
  ["optionals, defaults and honest or"] = [[
local function find(): string?
  return nil
end
local s: string = find() or "none"
local n: number = tonumber("1") or 0
local b: boolean = true or false
local maybe: string? = nil
local both: string? = find() or nil
if maybe then
end
while find() do
end
]],
  ["calls, overloads and methods"] = [[
local function opt(a: integer, b?: string, ...: number): string
  return b or "d"
end
local x = opt(1)
local y = opt(1, "b", 2.5, 3)
local up: string = ("abc"):upper()
local s = "abc"
local sub: string = s:sub(1, 2)
local replaced, count = s:gsub("a", "b")
local mapped = s:gsub("a", function(c: string): string return c end)
local function two(): integer, string
  return 1, "a"
end
local one, other = two()
print(two())
print(opt(1), 2, "x")
local last: string = string.format("%d", one)
]],
  ["function literals take their types from the position"] = [[
local function apply(f: function(integer, string): string): string
  return f(1, "a")
end
local r: string = apply(function(n, s) return s .. tostring(n) end)
local handlers: {string: function(integer): integer} = {
  double = function(n) return n * 2 end,
}
local never: function(string): never = function(m) error(m) end
]],
  ["loops"] = [[
local xs: mut {integer} = {}
for i = 1, 10 do
  xs[#xs + 1] = i
end
for i = 10, 1, -2 do
  local half: integer = i // 2
end
local record State
  mut n: integer
end
local state: State = { n = 0 }
local function counter(): function(): integer?
  return function(): integer?
    state.n = state.n + 1
    return state.n
  end
end
for v in counter() do
  local doubled: integer = v * 2
end
repeat
  xs = {}
until #xs == 0
]],
  ["indexes and writes"] = [[
local m: mut {string: integer} = {}
m["a"] = 1
m["b"] = nil
local got: integer = m["a"] or 0
local xs: mut {string} = {}
xs[#xs + 1] = "a"
]],
  ["returns of several lists"] = [[
local function a(): string?, string
  return nil, "why"
end
local function b(s: string): string?, string
  if s == "" then
    return nil, "empty"
  end
  return s, ""
end
local function c(): (true, integer) | (false, string)
  return true, 1
end
local function d(): (true, integer) | (false, string)
  return false, "no"
end
local function e(): string?, string
  return b("x")
end
local function f(): never
  error("never")
end
]],
  ["modules"] = [[
local M = require("m")
local v: integer = M.f(1)
local w: integer = M.count
]],
}

local MODULES <const>: {string: string} = {
  m = "local record M\n  count: integer\nend\nfunction M.f(a: integer): integer\n  return a\nend\nreturn M\n",
}

local function test_programs_that_follow_the_rules_check_clean()
  local names: {string} = {}
  for name in pairs(STANDING) do
    names[#names + 1] = name
  end
  table.sort(names)
  local problems: {string} = {}
  for _, name in ipairs(names) do
    local r = Programs.run(STANDING[name], MODULES)
    local found: {string} = {}
    for _, e in ipairs(r.errors) do
      found[#found + 1] = e.y .. ":" .. e.x .. " " .. e.code .. " " .. e.msg
    end
    for _, c in ipairs(r.before) do
      found[#found + 1] = "before: " .. c
    end
    if #found > 0 then
      problems[#problems + 1] = name .. ":\n  " .. table.concat(found, "\n  ")
    end
  end
  assert(#problems == 0, table.concat(problems, "\n"))
end

-- the types of names ---------------------------------------------------------------------------------

--- The display of the type of each variable `names` lists (space separated) in `r`.
local function shown(r: Programs.Run, names: {string}): {string: string}
  local out: {string: string} = {}
  for _, name in ipairs(names) do
    out[name] = Types.display(Programs.var(r, name))
  end
  return out
end

local function test_a_local_has_the_type_of_its_annotation_or_its_value()
  local r = Programs.run([[
local a = 1
local b = 1.5
local c = "s"
local d = true
local e = nil
local f = { 1, 2 }
local g = { x = 1 }
local h: {string}? = nil
local i = a + b
local j = a // 2
local k = #c
local l = a < b
local m = not d
local n = a / 2
local o = c .. c
local p = -a
local q = if d then 1 else 2.5 end
local function two(): integer, string?
  return 1, nil
end
local r1, r2 = two()
local fn = two
]])
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  local got = shown(r, { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r1", "r2", "fn" })
  local want: {string: string} = {
    a = "integer", b = "number", c = "string", d = "boolean", e = "nil", f = "mut {integer}", g = "mut {string: integer}",
    h = "{string}?", i = "number", j = "integer", k = "integer", l = "boolean", m = "boolean", n = "number", o = "string",
    p = "integer", q = "number", r1 = "integer", r2 = "string?", fn = "function(): integer, string?",
  }
  for name, display in pairs(want) do
    assert(got[name] == display, name .. " is " .. tostring(got[name]) .. ", wanted " .. display)
  end
end

local function test_parameters_loop_variables_and_the_names_of_a_module_have_their_types()
  local r = Programs.run([[
local m = require("m")
local record Item
  n: integer
  tags: {string}
end
local function f(item: Item, rest?: string, ...: number): integer
  local first = ...
  for i = 1, item.n do
    local j = i
  end
  for k = 1.5, 3 do
    local x = k
  end
  return item.n
end
local up = ("a"):upper()
local count = m.count
local pick = m.f(1)
]], { m = "local record M\n  count: integer\nend\nfunction M.f(a: integer): integer\n  return a\nend\nreturn M\n" })
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r) .. (r.errors[1] ~= nil and r.errors[1].msg or ""))
  local got = shown(r, { "item", "rest", "first", "i", "j", "k", "x", "up", "count", "pick" })
  local want: {string: string} = {
    item = "Item", rest = "string?", first = "number?", i = "integer", j = "integer", k = "number", x = "number",
    up = "string", count = "integer", pick = "integer",
  }
  for name, display in pairs(want) do
    assert(got[name] == display, name .. " is " .. tostring(got[name]) .. ", wanted " .. display)
  end
end

local function test_a_call_with_several_lists_gives_each_name_the_union_of_its_column_and_no_value_to_one_name()
  local r = Programs.run([[
local f: function(): (true, integer) | (false, string)
local ok, v = f()
]])
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  assert(Types.display(Programs.var(r, "ok")) == "boolean" and Types.display(Programs.var(r, "v")) == "integer | string")
end

local function test_the_first_overload_that_accepts_is_taken_and_a_literal_is_checked_against_it()
  local r = Programs.run([[
local a, n = ("x"):gsub("a", "b")
local b = ("x"):gsub("a", function(c: string): string return c end)
local c = ("x"):gsub("a", function(c: integer): string return "" end)
]])
  assert(#r.before == 0 and Programs.codes(r) == "not_assignable", Programs.codes(r))
  assert(Types.display(Programs.var(r, "a")) == "string" and Types.display(Programs.var(r, "n")) == "integer")
  local e = r.errors[1]
  assert(e.y == 3 and has(e.msg, "`function(c: integer): string return \"\" end` is `function(integer): string`, where " ..
      "`function(string): string` is wanted as argument 2"), e.msg)
end

local function test_a_function_literal_takes_its_returns_from_the_position_and_the_body_is_checked_against_them()
  local r = Programs.run([[
local function apply(f: function(string): string): string
  return f("a")
end
local x = apply(function(s) return s .. 1 end)
local y = apply(function(s) return 2 end)
]])
  assert(#r.before == 0 and Programs.codes(r) == "concat_type not_assignable", Programs.codes(r))
end

local function test_a_class_method_has_self_and_the_fields_of_its_class_and_a_generic_body_reads_through_its_bound()
  local r = Programs.run([[
local interface Sized
  size: integer
end
local class Bag is Sized
  size: integer
  mut count: integer
  function add(self, n: integer): integer
    self.count = self.count + n
    return self.size + self.count
  end
  function bad(self): string
    self.size = 1
    return self.count
  end
end
local function total<T is Sized>(a: T, b: T): integer
  return a.size + b.size
end
]])
  assert(#r.before == 0 and Programs.codes(r) == "field_fixed not_assignable", Programs.codes(r))
end

local function test_a_statement_that_defines_a_function_of_a_record_is_the_field_and_is_held_to_it()
  local r = Programs.run([[
local record R
  declared: function(integer): integer
end
function R.declared(n: string): integer
  return 1
end
function R.defined(n: integer): integer
  return n
end
local x: integer = R.defined(1)
local y: string = R.defined(1)
]])
  assert(#r.before == 0 and Programs.codes(r) == "not_assignable not_assignable", Programs.codes(r))
  assert(r.errors[1].y == 4 and has(r.errors[1].msg, "as the declaration of `R.declared`"), r.errors[1].msg)
end

local function test_a_global_value_a_declaration_file_gives_and_a_global_record_are_typed_from_the_declarations()
  local r = Programs.run([[
local s: string = tostring(1)
local u = string.upper("x")
local n: integer = tostring(1)
local v = print
]])
  assert(#r.before == 0 and Programs.codes(r) == "not_assignable", Programs.codes(r))
  assert(Types.display(Programs.var(r, "u")) == "string" and Types.display(Programs.var(r, "v")) == "function(...: any)")
end

local function test_a_chain_of_any_length_is_checked_without_recursion()
  local terms: {string} = {}
  for i = 1, 30000 do
    terms[i] = "a"
  end
  local r = Programs.run("local a: integer = 1\nlocal b: integer = " .. table.concat(terms, " + ") .. "\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r) .. (r.before[1] or ""))
  local hops: {string} = {}
  for i = 1, 30000 do
    hops[i] = ".next"
  end
  local c = Programs.run("local record Node\n  next: Node\nend\nlocal n: Node\nlocal deep = n" .. table.concat(hops) .. "\n")
  assert(#c.before == 0 and #c.errors == 0 and Types.display(Programs.var(c, "deep")) == "Node", Programs.codes(c))
end

-- holes a review found ----------------------------------------------------------------------------------

--- The codes of checking `source` (with `modules`), which has no error of the parser, the scopes or the lowering.
local function codes_of(source: string, modules?: {string: string}): string
  local r = Programs.run(source, modules)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  return Programs.codes(r)
end

local TAILED <const> = "local tailed: function(): string...\n"

local function test_the_arms_of_an_if_expression_are_held_to_the_type_the_position_wants_when_they_have_no_join()
  local head = "local b: boolean = true\nlocal enum Color \"red\" \"green\" end\n"
  assert(codes_of(head .. "local x: string = if b then 1 else \"a\" end\n") == "not_assignable")
  assert(codes_of(head .. "local x: string = if b then \"a\" elseif b then 2 else 3 end\n") == "not_assignable not_assignable")
  assert(codes_of(head .. "local x: integer? = if b then 1 else nil end\n") == "")
  -- the position's type reaches the arms: a string is a member of the enum or it is not
  assert(codes_of(head .. "local c: Color = if b then \"red\" else \"blue\" end\n") == "enum_member")
  assert(codes_of(head .. "local c: Color = if b then \"red\" else \"green\" end\n") == "")
  assert(codes_of("local function f(a: any)\nend\nlocal b: boolean = true\nf(if b then 1 else \"a\" end)\n") == "arms_differ")
end

local function test_a_write_through_a_union_or_onto_a_string_is_refused()
  local source = "local enum AK \"a\" end\nlocal enum BK \"b\" end\n" ..
    "local record A\n  kind: AK\n  mut x: string\nend\nlocal record B\n  kind: BK\n  mut x: string\nend\n" ..
    "local function f(u: A | B, s: string)\n"
  assert(codes_of(source .. "  u.x = \"wrong\"\nend\n") == "field_fixed")
  assert(codes_of(source .. "  s.upper = nil\nend\n") == "field_fixed")
  local r = Programs.run(source .. "  u.x = 1\nend\n")
  assert(has(r.errors[1].fix, "narrow the value to one record, then write its `mut` field"), r.errors[1].fix)
end

local function test_the_tail_a_return_ends_in_is_held_to_the_return_list()
  local function g(ret: string, value: string): string
    return codes_of(TAILED .. "local function g(): " .. ret .. "\n  return " .. value .. "\nend\n")
  end
  assert(g("string", "tailed()") == "nil_not_allowed", g("string", "tailed()"))
  assert(g("string?", "tailed()") == "", g("string?", "tailed()"))
  assert(g("integer?", "tailed()") == "not_assignable", g("integer?", "tailed()"))
  assert(g("string?, string?", "tailed()") == "", g("string?, string?", "tailed()"))
  assert(g("string?", "\"a\", tailed()") == "return_arity", g("string?", "\"a\", tailed()"))
  local r = Programs.run("local function g(...: string): string\n  return ...\nend\n")
  assert(#r.before == 0 and Programs.codes(r) == "nil_not_allowed" and has(r.errors[1].fix, "varargs end in nil"))
  assert(codes_of("local function g(...: string): string?\n  return ...\nend\n") == "")
end

local function test_the_tail_and_the_lists_of_a_last_item_of_a_literal_are_checked()
  assert(codes_of(TAILED .. "local xs: {integer} = { tailed() }\n") == "not_assignable")
  assert(codes_of(TAILED .. "local xs: {string} = { 1, tailed() }\n") == "not_assignable")
  assert(codes_of(TAILED .. "local xs: {string} = { \"a\", tailed() }\n") == "")
  assert(codes_of(TAILED .. "local record L is {integer}\nend\nlocal l: L = { tailed() }\n") == "not_assignable")
  local lists = "local f: function(): (true, integer) | (false, string)\n"
  assert(codes_of(lists .. "local xs = { f() }\n") == "alternatives_as_value")
  assert(codes_of(lists .. "local xs: {integer} = { f() }\n") == "alternatives_as_value")
  assert(codes_of(lists .. "local record L is {integer}\nend\nlocal l: L = { f() }\n") == "alternatives_as_value")
end

local function test_a_local_with_no_type_and_no_value_is_reported()
  local r = Programs.run("local x, y: integer\nlocal z: integer\n")
  assert(#r.before == 0 or r.before[1] ~= nil)
  assert(Programs.codes(r) == "local_untyped" or Programs.codes(r) == "", Programs.codes(r))
  assert(codes_of("local x\n") == "local_untyped")
  assert(codes_of("local x: integer\nlocal y: integer? = nil\n") == "")
end

local function test_a_module_that_returns_a_function_gives_its_importers_the_type_of_the_function()
  local modules: {string: string} = {
    f = "local function f(a: integer): integer\n  return a\nend\nreturn f\n",
    lit = "return function(a: string): string\n  return a\nend\n",
    typed = "local g: function(string): integer = nil\nreturn g\n",
    plain = "local t = { 1 }\nreturn t\n",
  }
  assert(codes_of("local f = require(\"f\")\nlocal s: string = f(1)\n", modules) == "not_assignable")
  assert(codes_of("local f = require(\"f\")\nlocal n: integer = f(1)\n", modules) == "")
  assert(codes_of("local f = require(\"lit\")\nlocal n: integer = f(\"a\")\n", modules) == "not_assignable")
  assert(codes_of("local g = require(\"typed\")\nlocal n: integer = g(\"a\")\n", modules) == "")
  -- a module whose value has no written type is reported where it is returned and where it is required
  assert(codes_of("local t = require(\"plain\")\n", modules) == "unchecked_binding")
  assert(Programs.codes(Programs.run(modules.plain)) == "export_not_declared")
end

local function test_a_returned_local_declared_with_a_type_of_an_imported_module_is_an_export()
  local modules: {string: string} = {
    mt = "local record T\n  n: integer\nend\nreturn T\n",
    mu = "local T = require(\"mt\")\nlocal x: T = { n = 1 }\nreturn x\n",
  }
  local r = Programs.run("local U = require(\"mu\")\nlocal v: integer = U.n\n", modules)
  assert(#r.before == 0 and Programs.codes(r) == "", Programs.codes(r) .. (r.errors[1] ~= nil and r.errors[1].msg or ""))
  assert(r.program.modules.mu.export ~= nil)
end

local function test_a_loop_over_a_call_that_gives_no_iterator_is_reported()
  assert(codes_of("local function f()\nend\nfor x in f() do\nend\n") == "no_value")
  assert(codes_of("local f: function(): (true, integer) | (false, string)\nfor x in f() do\nend\n") == "alternatives_as_value")
end

local function test_a_function_statement_with_no_name_does_not_stop_the_check()
  local r = Programs.run("function() end\nlocal x: integer = \"a\"\n")
  assert(#r.before > 0)
  assert(Programs.codes(r) == "not_assignable", Programs.codes(r))
end

local function test_only_a_literal_nil_deletes_a_key_of_a_map()
  local head = "local m: mut {string: integer} = {}\nlocal v: integer? = nil\n"
  assert(codes_of(head .. "m[\"a\"] = v\n") == "nil_not_allowed")
  assert(codes_of(head .. "m[\"a\"] = nil\nm[\"b\"] = 1\n") == "")
  assert(codes_of(head .. "m[\"a\"], m[\"b\"] = nil, v\n") == "nil_not_allowed")
end

local function test_a_string_literal_on_the_left_of_an_equality_is_held_to_an_optional_enum()
  local head = "local enum Color \"red\" \"green\" end\nlocal c: Color? = nil\n"
  assert(codes_of(head .. "local a = \"red\" == c\nlocal b = c == \"red\"\n") == "")
  assert(codes_of(head .. "local a = \"blue\" == c\n") == "enum_member")
  assert(codes_of(head .. "local b = c == \"blue\"\n") == "enum_member")
end

local function test_a_default_string_for_an_optional_enum_joins_to_a_string()
  local head = "local enum Color \"red\" \"green\" end\nlocal c: Color? = nil\n"
  local r = Programs.run(head .. "local s = c or \"x\"\nlocal d: Color = c or \"red\"\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r))
  assert(Types.display(Programs.var(r, "s")) == "string")
  assert(codes_of(head .. "local d: Color = c or \"x\"\n") == "enum_member")
end

local function test_a_key_that_is_invalid_names_no_second_error_on_a_record()
  local head = "local record R\n  a: integer\nend\nlocal r: R = { a = 1 }\n"
  assert(codes_of(head .. "local x = r[r.nam]\n") == "field_unknown")
  assert(codes_of(head .. "r[r.nam] = 1\n") == "field_unknown")
end

local function test_the_array_part_of_a_record_is_a_view_and_a_write_to_it_says_so()
  local head = "local record L is {integer}\n  name: string\nend\nlocal l: L = { 1, 2, name = \"a\" }\n"
  assert(codes_of(head .. "local x: integer? = l[1]\nlocal n: integer = #l\n") == "")
  assert(codes_of(head .. "l[1] = 3\n") == "view_written")
  assert(codes_of(head .. "l[#l + 1] = 3\n") == "view_written")
  assert(codes_of(head .. "local k: string = \"name\"\nl[k] = \"b\"\n") == "record_index")
end

local function test_a_parenthesised_literal_and_an_if_expression_of_functions_pick_the_overload_they_fit()
  local head = "local b: boolean = true\nlocal function up(c: string): string\n  return c\nend\n"
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", (function(c: string): string return c end))\n") == "")
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", if b then up else up end)\n") == "")
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", if b then function(c: string): string return c end else up end)\n") == "")
  assert(codes_of(head .. "local r = (\"x\"):gsub(\"a\", if b then \"y\" else \"z\" end)\n") == "")
end

local function test_every_variable_of_type_invalid_comes_with_an_error()
  local problems: {string} = {}
  local function hold(label: string, source: string, modules?: {string: string})
    local r = Programs.run(source, modules)
    if #r.before > 0 or #r.errors > 0 then
      return
    end
    for _, v in ipairs(r.scoped.list) do
      local t = r.result.vars[v.id]
      if t ~= nil and t.tag == "invalid" then
        problems[#problems + 1] = label .. ": " .. v.name .. " is invalid and nothing is reported"
      end
    end
  end
  for i, case in ipairs(CASES) do
    hold("case " .. i .. " " .. case.code, case.source, case.modules)
  end
  for name, source in pairs(STANDING) do
    hold(name, source, MODULES)
  end
  assert(#problems == 0, table.concat(problems, "\n"))
end
