--- Tests of [`lang.check`]: a case for each code it reports, with the place, message and fix; programs that stand;
--- the types of names; and the programs the fork accepts that build/teal_test.tl pins and the plan refuses, as
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
    code = "field_unknown", source = "local enum Kind\n  \"a\"\n  \"b\"\nend\nlocal k: Kind = \"a\"\nlocal x = k:upper()\n",
    msg = "`Kind` is an enum, whose values have no fields or methods: `upper` is not one",
    fix = "make it a string first, `tostring(v):upper(...)` or `string.upper(tostring(v), ...)`, or compare it with `==` to a member",
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
    code = "cannot_infer", source = "local function empty<T>(): mut {T}\n  return {}\nend\nlocal xs = empty()\n", at = { 4, 12 },
    msg = "`empty` is generic, and nothing fixes its type parameter `T`",
    fix = "type the result, so the call is expected to have the type (`local v: T = empty(...)`)",
  },
  {
    code = "infer_conflict", source = "local function pick<T>(a: T, b: T): T\n  return a\nend\nlocal n = 1\nlocal s = \"a\"\nlocal x = pick(n, s)\n",
    at = { 6, 19 }, msg = "`T` of `pick` is `integer` from argument 1 and `string` from argument 2, which have no common type",
    fix = "pass values of one type to `pick`, or convert argument 2 to `integer`",
  },
  {
    code = "bound_unmet",
    source = "local interface Named\n  name: string\nend\nlocal record Plain\n  name: string\nend\n" ..
      "local function label<T is Named>(x: T): string\n  return x.name\nend\nlocal p: Plain = { name = \"a\" }\nlocal s = label(p)\n",
    at = { 11, 11 }, msg = "`Plain` is the type parameter `T` of `label`, which is bounded by `Named`",
    fix = "list the interface in the declaration of `Plain` (`is Named`)",
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
    source = "local f: function(): (true, integer) | (false, string) = function() return true, 1 end\nlocal x = f()\n",
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
    code = "condition_type", source = "local function f(b: boolean?)\n  while b do\n  end\nend\n",
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
    code = "static_before_definition",
    source = "local class C\n  n: integer\nend\nlocal x: C = { n = 1 }\nlocal k = C.twice(x)\n" ..
      "function C.twice(self: C): integer\n  return 1\nend\n",
    at = { 5, 11 }, msg = "`C.twice` reads the function `C.twice` before the statement that defines it has run",
    fix = "move the statement `function C.twice(...)` above this use",
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
    msg = "the key `name` is written twice in this literal", fix = "remove the second `name`, or give the two different keys",
  },
  {
    code = "literal_repeated", source = "local t = { a = 1, a = 2 }\nlocal _ = t\n",
    msg = "the key `a` is written twice in this literal", fix = "remove the second `a`, or give the two different keys",
  },
  {
    code = "literal_repeated", source = "local t: {string: integer} = { a = 1, [\"a\"] = 2 }\nlocal _ = t\n",
    msg = "the key `a` is written twice in this literal", fix = "remove the second `a`, or give the two different keys",
  },
  {
    code = "literal_repeated", source = "local t: {integer: string} = { [1] = \"x\", [1] = \"y\" }\nlocal _ = t\n",
    msg = "the key 1 is written twice in this literal", fix = "remove the second 1, or give the two different keys",
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
    code = "missing_return", source = "local function f(): integer\n  local x = 1\nend\n", at = { 2, 3 },
    msg = "control can reach the end of this function, which answers (integer), with no `return`",
    fix = "end every path with a `return` of (integer) (or `error(...)`)",
  },
  {
    code = "missing_return", source = "local function f(): never\n  local x = 1\nend\n", at = { 2, 3 },
    msg = "this function is declared `never`, and control can reach its end",
    fix = "end every path with `error(...)` or a call of a function that never returns",
  },
  {
    code = "not_assigned", source = "local x: integer\nlocal y = x\n", at = { 2, 11 },
    msg = "`x` is read before every path assigns it: `local x` was given no value",
    fix = "assign `x` on every path before this read, give it a value where it is declared (`local x: integer = ...`), " ..
      "or declare it `integer?`",
  },
  {
    code = "unreachable", source = "local function f()\n  error(\"x\")\n  print(2)\nend\n", at = { 3, 3 },
    msg = "control never reaches this statement: what comes before it ends the block",
    fix = "remove it, or move it before the `return`, `break`, `continue`",
  },
  {
    code = "narrowing_dropped", at = { 8, 11 },
    source = FIND .. "local function f(): integer\n  local s = find()\n  if s == nil then return 0 end\n  s = find()\n" ..
      "  return #s\nend\n",
    msg = "(a test showed it was not nil, and the assignment at 7:3 dropped that)",
    fix = "test `s` again after the assignment at 7:3 (`if s == nil then return nil, why end`)",
  },
  {
    code = "narrows_unproved", source = "local function is_text(v: any): v is string\n  return true\nend\n", at = { 2, 3 },
    msg = "this function is declared `v is string`, and `true` does not show it when true: `v` is then `any`",
    fix = "return a test that decides `string` (`return v is T`",
  },
  {
    code = "iterator_extra", at = { 5, 23 },
    source = "local function it(): function(): integer\n  return function(): integer return 1 end\nend\nlocal f = it()\n" ..
      "for x in f, nil, nil, 3 do\n  print(x)\nend\n",
    msg = "a generic `for` takes an iterator, a state and a first control value", fix = "write at most three expressions",
  },
  {
    code = "iterator_variables", at = { 5, 11 },
    source = "local m: {string: integer} = {}\nlocal function pairs_of(): function(): (string, integer)\n  return function(): (string, integer) return \"a\", 1 end\nend\nfor a, b, c in pairs_of() do\nend\n",
    msg = "`c` is variable 3 of a `for`", fix = "name no more variables than the iterator answers",
  },
  {
    code = "pattern_malformed", at = { 1, 24 }, source = "local x = (\"abc\"):find(\"a)\")\nprint(x)\n",
    msg = "the pattern of `find` is malformed: `)` closes no capture (at character 2), and Lua raises \"invalid pattern capture\"",
    fix = "escape it as `%)` to match the character, or open the capture with `(` before it",
  },
  {
    code = "format_malformed", at = { 1, 25 }, source = "local x = string.format(\"%y\", 1)\nprint(x)\n",
    msg = "the format of `string.format` is malformed: `%y` is no conversion of `string.format` (at character 1), and Lua raises " ..
      "\"invalid conversion '%y' to 'format'\"",
    fix = "write `%d` or `%i` for an integer, `%f`, `%e` or `%g` for a number, `%s` for text",
  },
  {
    code = "pack_malformed", at = { 1, 23 }, source = "local x = string.pack(\"X\", 1)\nprint(x)\n",
    msg = "the format of `string.pack` is malformed: `X` aligns to nothing (at character 1), and Lua raises \"invalid next option " ..
      "for option 'X'\"",
    fix = "follow `X` with an option of a size, such as `Xi4`",
  },
  {
    code = "gsub_key", at = { 2, 30 }, source = "local repl: {integer: string} = {}\nlocal s = (\"abc\"):gsub(\"%w\", repl)\nprint(s)\n",
    msg = "the table of `gsub` is looked up with the captured text, a `string` as the key, and its keys are `integer`",
    fix = "declare the table `{string: string}`, or capture a position with `()` for integer keys",
  },
  {
    code = "paren_is", at = { 2, 11 }, source = "local x: integer | string = 1\nlocal y = (x) is integer\nprint(y)\n",
    msg = "`(x) is ...` tests a value: the parentheses make `x` no place, so the test narrows nothing",
    fix = "write `x is integer` without the parentheses, so that the test narrows it",
  },
  {
    code = "type_name", at = { 2, 15 }, source = "local x = 1\nif type(x) == \"int\" then\n  print(x)\nend\n",
    msg = "`type` never answers \"int\": it answers nil, boolean, number, string, table, function, thread or userdata, so the test is always false",
    fix = "compare with a name `type` answers; `math.type(x)` tells \"integer\" from \"float\"",
  },
  {
    code = "assign_repeated", source = "local x = 1\nx, x = 2, 3\n", at = { 2, 4 },
    msg = "`x` is assigned twice by one statement, and Lua leaves the order of the two open",
    fix = "assign `x` once, or in two statements in the order you mean",
  },
  {
    code = "match_missing", at = { 3, 1 },
    source = "local f: function(): (true, integer) | (false, string) = function() return true, 1 end\nlocal n = 0\nmatch f() do\n  | (true, v) then n = v\nend\n",
    msg = "this `match` takes no arm for the list `(false, string)` the call may answer", fix = "add the arm `| (false, v2) then ...`",
  },
  {
    code = "match_redundant",
    source = "local f: function(): (true, integer) | (false, string) = function() return true, 1 end\nmatch f() do\n  | (true, v) then print(v)\n  | (true, w) then print(w)\n  | (false, why) then print(why)\nend\n",
    msg = "this arm takes only lists the arms before it take, so it never runs",
    fix = "delete the arm, or change its `true` and `false` to take a list no arm before it takes",
  },
  {
    code = "match_pattern", at = { 3, 6 },
    source = "local f: function(): (boolean, integer) = function() return true, 1 end\nmatch f() do\n  | (true, v) then print(v)\nend\n",
    msg = "this pattern tests position 1 with `true`, and the list `(boolean, integer)` has `boolean` there",
    fix = "test only the positions that are `true` or `false` in the lists the call answers",
  },
  {
    code = "unchecked_binding", source = "local sys = require(\"cosmic.sys\")\n", at = { 1, 13 },
    msg = "the module `cosmic.sys` is a binding of C that has no declarations",
    fix = "call the library function that wraps the binding (`cosmic docs <name>` names it) in place of the raw binding; the bindings of C are typed once the checker reads them from declaration files",
  },
}

local function test_each_case_has_its_error_with_place_message_and_fix()
  local seen: mut {string: boolean} = {}
  local problems: mut {string} = {}
  for i, case in ipairs(CASES) do
    local r = Programs.run(case.source, case.modules)
    local label = "case " .. i .. " " .. case.code
    seen[case.code] = true
    if #r.before > 0 then
      problems[#problems + 1] = label .. ": the source has " .. table.concat(r.before, " ")
    elseif Programs.codes(r) ~= (case.codes or case.code) then
      problems[#problems + 1] = label .. ": has " .. Programs.codes(r) .. (if r.errors[1] ~= nil then " (" .. r.errors[1].msg .. ")" else "" end)
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
  local owned: mut {string: boolean} = {}
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
  ["generic calls over unions and iterators"] = [[
local function first<T>(xs: {T}): T?
  return xs[1]
end
local function widest(u: {integer} | {number}): number?
  return first(u)
end
local function sum(u: ({integer} | {number})?): number
  local total: number = 0
  if u ~= nil then
    for _, v in ipairs(u) do
      total = total + v
    end
  end
  return total
end
local names: {string: integer} = {}
for k, v in pairs(names) do
  print(k, v)
end
local whole: {integer} = { 1 }
local parts: {number} = { 1.5 }
print(widest(whole), sum(parts))
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
  local names: mut {string} = {}
  for name in pairs(STANDING) do
    names[#names + 1] = name
  end
  table.sort(names)
  local problems: mut {string} = {}
  for _, name in ipairs(names) do
    local r = Programs.run(STANDING[name], MODULES)
    local found: mut {string} = {}
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
  local out: mut {string: string} = {}
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
local f: function(): (true, integer) | (false, string) = function() return true, 1 end
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
  local terms: mut {string} = {}
  for i = 1, 30000 do
    terms[i] = "a"
  end
  local r = Programs.run("local a: integer = 1\nlocal b: integer = " .. table.concat(terms, " + ") .. "\n")
  assert(#r.before == 0 and #r.errors == 0, Programs.codes(r) .. (r.before[1] or ""))
  local hops: mut {string} = {}
  for i = 1, 30000 do
    hops[i] = ".next"
  end
  local c = Programs.run("local record Node\n  next: Node\nend\nlocal function chase(n: Node)\n  local deep = n" .. table.concat(hops) .. "\nend\n")
  assert(#c.before == 0 and #c.errors == 0 and Types.display(Programs.var(c, "deep")) == "Node", Programs.codes(c))
end

-- holes a review found ----------------------------------------------------------------------------------

--- The codes of checking `source` (with `modules`), which has no error of the parser, the scopes or the lowering.
local function codes_of(source: string, modules?: {string: string}): string
  local r = Programs.run(source, modules)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  return Programs.codes(r)
end

local TAILED <const> = "local tailed: function(): string... = function() end\n"

local function test_a_pragma_comment_changes_nothing_a_call_is_held_to_its_declared_arity()
  local call = "local function f(a: integer)\nend\nf(1, 2)\n"
  assert(codes_of(call) == "arity")
  assert(codes_of("--#pragma arity off\n" .. call) == "arity")
  assert(codes_of("--#pragma arity off\nlocal function f(a: integer)\nend\n--#pragma\nf()\n") == "arity")
  assert(codes_of("--#pragma arity off\nlocal function f(a: integer)\nend\nf(1)\n") == "")
end

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
  local lists = "local f: function(): (true, integer) | (false, string) = function() return true, 1 end\n"
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
  assert(codes_of("local f: function(): (true, integer) | (false, string) = function() return true, 1 end\nfor x in f() do\nend\n") == "alternatives_as_value")
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
  local head = "local enum Color \"red\" \"green\" end\nlocal function pick(): Color?\n  return nil\nend\nlocal c: Color? = pick()\n"
  assert(codes_of(head .. "local a = \"red\" == c\nlocal b = c == \"red\"\n") == "")
  assert(codes_of(head .. "local a = \"blue\" == c\n") == "enum_member")
  assert(codes_of(head .. "local b = c == \"blue\"\n") == "enum_member")
end

local function test_a_default_string_for_an_optional_enum_joins_to_a_string()
  local head = "local enum Color \"red\" \"green\" end\nlocal function pick(): Color?\n  return nil\nend\nlocal c: Color? = pick()\n"
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

--- The problems of the variables of type `invalid` that nothing was reported for, in the cases from `first` to `last` and,
--- where `standing`, in the standing programs. Split in three tests so that none runs near the limit of a test.
local function silent_invalids(first: integer, last: integer, standing: boolean): {string}
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
  for i = first, math.min(last, #CASES) do
    local case = CASES[i]
    hold("case " .. i .. " " .. case.code, case.source, case.modules)
  end
  if standing then
    for name, source in pairs(STANDING) do
      hold(name, source, MODULES)
    end
  end
  return problems
end

local function test_every_variable_of_type_invalid_comes_with_an_error_in_the_first_cases()
  local problems = silent_invalids(1, #CASES // 2, false)
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_every_variable_of_type_invalid_comes_with_an_error_in_the_last_cases()
  local problems = silent_invalids(#CASES // 2 + 1, #CASES, false)
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_every_variable_of_type_invalid_comes_with_an_error_in_the_standing_programs()
  local problems = silent_invalids(1, 0, true)
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_a_generic_for_closes_only_a_fourth_value_it_can_see_and_takes_three_expressions()
  local head = "local function it(): function(): integer\n  return function(): integer return 1 end\nend\nlocal f = it()\n"
  local step = "local type Step = function(): integer\n"
  local function four(last: string): string
    return step .. "local function four(): (Step, nil, nil, " .. last .. ")\n  return function(): integer return 1 end, nil, nil, " ..
      (if last == "nil" then "nil" else "3" end) .. "\nend\nfor x in four() do\n  print(x)\nend\n"
  end
  local said: {string} = {
    -- three expressions are an iterator, a state and a control value
    codes_of(head .. "for x in f, nil, nil do\n  print(x)\nend\n"),
    codes_of(head .. "for x in f, nil, 1 do\n  print(x)\nend\n"),
    -- a call that answers four values: the fourth is the value to close, unless it is nil
    codes_of(four("integer")),
    codes_of(four("nil")),
    -- an iterator that answers a `...` tail, or nil alone, takes any number of names
    codes_of("local function tail(): function(): integer...\n  return function(): integer... return 1, 2 end\nend\n" ..
        "for a, b, c, d in tail() do\n  print(a, b, c, d)\nend\n"),
    codes_of("local function none(): function(): nil\n  return function(): nil return nil end\nend\n" ..
        "for a, b in none() do\n  print(a, b)\nend\n"),
    -- the most of the lists an iterator answers sets the names it may take
    codes_of("local function more(): function(): (true, integer) | (false, string, boolean)\n" ..
        "  return function(): (true, integer) return true, 1 end\nend\nfor a, b, c in more() do\n  print(a, b, c)\nend\n"),
    codes_of("local function more(): function(): (true, integer) | (false, string, boolean)\n" ..
        "  return function(): (true, integer) return true, 1 end\nend\nfor a, b, c, d in more() do\n  print(a, b, c, d)\nend\n"),
  }
  assert(table.concat(said, " | ") == " |  | iterator_extra |  |  |  |  | iterator_variables", table.concat(said, " | "))
end

--- An iterator that ends after two values, and a function that answers it with `values` after it.
local COUNTED <const> = "local type Step = function(state: nil, control: integer?): integer?\n" ..
  "local function st(_state: nil, control: integer?): integer?\n  if control == nil then\n    return 1\n  elseif control == 1 then\n" ..
  "    return 0\n  end\n  return nil\nend\n"

--- A loop over `explist`, where `mk` answers `answer` as `values`.
local record Looped
  values: string
  answer: string
  explist: string
end

--- The program that loops over what `looped` says, with the iterator `st` that ends after two values.
local function loop_over(looped: Looped): string
  return COUNTED .. "local function mk(): " .. looped.values .. "\n  return " .. looped.answer .. "\nend\nfor x in " ..
    looped.explist .. " do\n  print(x)\nend\n"
end

local function test_a_generic_for_over_values_that_may_include_a_fourth_is_refused_and_the_fourth_would_be_closed()
  -- The values after the third are any number, and the fourth is the value Lua closes when the loop ends.
  local tails: {Looped} = {
    { values = "(Step, nil, nil, integer...)", answer = "st, nil, nil, 5", explist = "mk()" },
    { values = "(Step, nil, integer...)", answer = "st, nil, 1, 5", explist = "mk()" },
    { values = "(nil, nil, integer...)", answer = "nil, nil, 5", explist = "st, mk()" },
  }
  for _, looped in ipairs(tails) do
    local source = loop_over(looped)
    assert(codes_of(source) == "iterator_extra", looped.values .. ": " .. codes_of(source))
    local x = Programs.execute(source, false, nil, nil, nil, true)
    local fault = x.fault or ""
    assert(x.ran and fault:find("closable", 1, true) ~= nil, looped.values .. ": " .. fault)
  end
  local refused = Programs.run(loop_over({ values = "(Step, nil, nil, integer...)", answer = "st, nil, nil", explist = "mk()" }))
  local message = refused.errors[1]
  assert(message ~= nil, "no error")
  assert(message.msg:find("`mk()` answers any number of `integer` values after those it lists", 1, true) ~= nil, message.msg)
  assert(message.fix:find("name the three values first", 1, true) ~= nil, message.fix)
  -- a tail of a type the checker refused is told once, by the type
  local unknown = Programs.run(loop_over({ values = "(Step, nil, nil, Nowhere...)", answer = "st, nil, nil", explist = "mk()" }))
  assert(table.concat(unknown.before, " ") == "unknown_type" and Programs.codes(unknown) == "", Programs.codes(unknown))
  -- the rest parameter of the function is any number of values as well
  assert(codes_of(COUNTED .. "local function each(...: Step)\n  for x in ... do\n    print(x)\n  end\nend\nprint(each)\n") ==
      "iterator_extra")
end

local function test_a_generic_for_over_the_three_values_it_takes_runs_and_closes_nothing()
  local taken: {Looped} = {
    -- exactly an iterator, a state and a control value
    { values = "(Step, nil, nil)", answer = "st, nil, nil", explist = "mk()" },
    -- a tail of nil gives none
    { values = "(Step, nil...)", answer = "st", explist = "mk()" },
    -- the three expressions after `in`
    { values = "(Step, nil, nil)", answer = "st, nil, nil", explist = "st, nil, nil" },
  }
  for _, looped in ipairs(taken) do
    local source = loop_over(looped)
    assert(codes_of(source) == "", looped.values .. ": " .. codes_of(source))
    local x = Programs.execute(source, false)
    assert(x.ran and x.fault == nil and table.concat(x.printed, ",") == "1,0", looped.values .. ": " .. tostring(x.fault))
  end
  -- the first three values of any number, named first, are an iterator, a state and a control value
  local named = COUNTED .. "local function mk(): (Step, nil, nil, integer...)\n  return st, nil, nil, 5\nend\n" ..
    "local iterator, state, control = mk()\nfor x in iterator, state, control do\n  print(x)\nend\n"
  assert(codes_of(named) == "", codes_of(named))
  local x = Programs.execute(named, false)
  assert(x.fault == nil and table.concat(x.printed, ",") == "1,0", tostring(x.fault))
end

local function test_a_literal_of_the_string_library_is_read_only_where_the_call_is_the_librarys()
  local said: {string} = {
    -- a method of text, the function by its name, and the receiver of `format`
    codes_of("local x = (\"abc\"):gsub(\"(\", \"x\")\nprint(x)\n"),
    codes_of("local x = string.find(\"abc\", \"[\")\nprint(x)\n"),
    codes_of("local x = (\"%y\"):format(1)\nprint(x)\n"),
    -- the text the pattern is not taken as, the pattern that is right, and the values a format asks for
    codes_of("local x = string.find(\"abc\", \")\", 1, true)\nprint(x)\n"),
    codes_of("local x = (\"abc\"):gsub(\"(%w)\", \"%1%0\")\nprint(x)\n"),
    codes_of("local function two(): (integer, integer)\n  return 1, 2\nend\nlocal x = string.format(\"%d %d\", two())\nprint(x)\n"),
    codes_of("local x = string.format(\"%d %d\", 1)\nprint(x)\n"),
    codes_of("local x = string.format(\"%d %%\", 1)\nprint(x)\n"),
    -- a record with a method of the same name
    codes_of("local record Finder\n  find: function(Finder, string): integer\nend\nlocal function use(f: Finder): integer\n" ..
        "  return f:find(\"(\")\nend\nprint(use)\n"),
    -- a table keyed as the pattern captures, and one keyed the other way
    codes_of("local repl: {string: string} = {}\nlocal s = (\"abc\"):gsub(\"%w\", repl)\nprint(s)\n"),
    codes_of("local repl: {integer: string} = {}\nlocal s = (\"abc\"):gsub(\"()\", repl)\nprint(s)\n"),
    codes_of("local repl: {string: string} = {}\nlocal s = (\"abc\"):gsub(\"()\", repl)\nprint(s)\n"),
    codes_of("local repl: {integer: string} = {}\nlocal p: string = \"%w\"\np = p .. \"\"\nlocal s = (\"abc\"):gsub(p, repl)\nprint(s)\n"),
  }
  assert(table.concat(said, " | ") == "pattern_malformed | pattern_malformed | format_malformed |  |  |  | arity |  |  |  |  | gsub_key | ",
    table.concat(said, " | "))
end

local function test_type_is_compared_with_the_eight_names_it_answers_and_is_tests_a_place_not_a_value()
  local said: mut {string} = {}
  for _, name in ipairs({ "nil", "boolean", "number", "string", "table", "function", "thread", "userdata" }) do
    said[#said + 1] = codes_of("local x: integer | string = 1\nlocal y = type(x) == \"" .. name .. "\"\nprint(y)\n")
  end
  assert(table.concat(said, "|") == "|||||||", table.concat(said, "|"))
  local function refused(source: string): string
    return codes_of(source)
  end
  -- the name on either side, either test, a name that is a type of the program, and a name held in a variable
  assert(refused("local x = 1\nprint(\"int\" == type(x))\n") == "type_name")
  assert(refused("local x = 1\nprint(type(x) ~= \"integer\")\n") == "type_name")
  assert(refused("local x = 1\nprint((type(x)) == \"float\")\n") == "type_name")
  assert(refused("local x = 1\nprint(type(x) == \"Number\")\n") == "type_name")
  assert(refused("local x = 1\nlocal k = \"int\"\nprint(type(x) == k)\n") == "")
  assert(refused("local x = 1\nlocal y = tostring(x)\nprint(y == \"int\")\n") == "")
  -- `(x) is T` for a name or a field is refused; any other parenthesized value is a test of that value
  local head = "local record R\n  v: integer | string\nend\nlocal r: R = { v = 1 }\nlocal x: integer | string = 1\n"
  assert(refused(head .. "print((x) is integer)\n") == "paren_is")
  assert(refused(head .. "print((r.v) is integer)\n") == "paren_is")
  assert(refused(head .. "print(((x)) is integer)\n") == "paren_is")
  assert(refused(head .. "print(x is integer)\n") == "")
  assert(refused(head .. "print(r.v is integer)\n") == "")
  assert(refused(head .. "print((x == 1) is boolean)\n") == "")
  assert(refused(head .. "print((tostring(x)) is string)\n") == "")
end

local function test_the_arguments_of_a_library_call_are_read_where_they_are_written()
  local function msg_of(source: string): string
    local r = Programs.run(source)
    local first = r.errors[1]
    return first ~= nil and first.msg or ""
  end
  local said: {string} = {
    -- the plain argument of a method call is the third argument, and `false` is no plain text
    codes_of("local x = (\"abc\"):find(\"a)\", 1, true)\nprint(x)\n"),
    codes_of("local x = (\"abc\"):find(\"a)\", 1, false)\nprint(x)\n"),
    -- a literal in parentheses, and a call or `...` that may give several values in the last place
    codes_of("local x = (\"abc\"):find((\"a)\"))\nprint(x)\n"),
    codes_of("local function f(...: integer): string\n  return string.format(\"%d %d\", ...)\nend\nprint(f)\n"),
    codes_of("local function two(): (string, string)\n  return \"a\", \"b\"\nend\nprint(string.format(\"%s %s\", two()))\n"),
    codes_of("local function two(): (string, string)\n  return \"a\", \"b\"\nend\nprint(string.format(\"%s %s\", (two())))\n"),
    -- a function of a record that is called `find`, a size that depends on the value, and `type` with two arguments
    codes_of("local record Finder\n  find: function(string, string): integer\nend\nlocal finder: Finder = { find = function(a: string, b: string): integer return 1 end }\n" ..
        "print(finder.find(\"a\", \"(\"))\n"),
    codes_of("print(string.packsize(\"z\"), string.packsize(\"i4\"))\n"),
    codes_of("local x = 1\nprint(type(x, 1) == \"int\")\n"),
  }
  assert(table.concat(said, " | ") == " | pattern_malformed | pattern_malformed | nil_not_allowed |  | arity |  | pack_malformed | arity",
    table.concat(said, " | "))
  -- the error stands on the literal: the receiver of a method call is the first argument
  local r = Programs.run("local x = (\"%y\"):format(1)\nprint(x)\n")
  local first = r.errors[1]
  assert(first ~= nil and first.y == 1 and first.x == 11 and first.length == 6, tostring(first ~= nil and first.length))
  -- and `~=` says the test is always true
  assert(has(msg_of("local x = 1\nprint(type(x) ~= \"int\")\n"), "so the test is always true"))
  assert(has(msg_of("local x = 1\nprint(type(x) == \"int\")\n"), "so the test is always false"))
end

local function test_the_types_a_literal_gives_are_held_to_the_arguments_and_the_results_of_a_library_call()
  local said: {string} = {
    -- the argument each conversion and option takes
    codes_of("print(string.format(\"%d\", \"x\"))\n"),
    codes_of("print(string.format(\"%d\", 1.5))\n"),
    codes_of("print(string.format(\"%c\", \"a\"))\n"),
    codes_of("print(string.format(\"%f\", true))\n"),
    codes_of("print(string.pack(\"i\", \"x\"))\n"),
    codes_of("print(string.pack(\"z\", 1))\n"),
    codes_of("print(string.format(\"%d %x %f %e %s %q\", 1, 2, 3, 4.5, \"t\", false))\n"),
    codes_of("print(string.pack(\"i4 d z\", 1, 2.5, \"s\"))\n"),
    -- a value too many is no value Lua uses, and a call that answers fewer than the format takes is told
    codes_of("print(string.format(\"%d\", 1, 2))\n"),
    codes_of("local function f(): integer\n  return 1\nend\nprint(string.format(\"%d %d\", f()))\n"),
    codes_of("local function f(): (integer, integer)\n  return 1, 2\nend\nprint(string.format(\"%d %d\", f()))\n"),
    -- the results of `unpack`, a position capture and the other captures
    codes_of("local a, b = string.unpack(\"i4\", \"abcd\")\nlocal n: integer = a\nlocal m: integer = b\nprint(n, m)\n"),
    codes_of("local a = string.unpack(\"z\", \"abcd\")\nlocal n: integer = a\nprint(n)\n"),
    codes_of("for p in (\"abc\"):gmatch(\"()\") do\n  local s: string = p\n  print(s)\nend\n"),
    codes_of("for p in (\"abc\"):gmatch(\"()\") do\n  local n: integer = p\n  print(n)\nend\n"),
    codes_of("for k, v in (\"a=1\"):gmatch(\"(%w)=(%w)\") do\n  print(k:upper(), v:upper())\nend\n"),
    codes_of("local _, _, p = (\"abc\"):find(\"()\")\nlocal s: string = p\nprint(s)\n"),
    codes_of("local _, _, c = (\"abc\"):find(\"(b)\")\nif c ~= nil then\n  print(c:upper())\nend\n"),
    -- a callback takes the captures: an integer for `()`, and no more parameters than the pattern has captures
    codes_of("print((\"abc\"):gsub(\"()\", function(p: string): string return p:upper() end))\n"),
    codes_of("print((\"abc\"):gsub(\"()\", function(p: integer): string return tostring(p) end))\n"),
    codes_of("print((\"abc\"):gsub(\"%w\", function(c: string, d: string): string return c end))\n"),
    -- a literal held in a local, and a library function held in a local, are read; a local that is assigned is not
    codes_of("local P <const> = \"%b(\"\nprint((\"abc\"):find(P))\n"),
    codes_of("local P = \"%b(\"\nprint((\"abc\"):find(P))\n"),
    codes_of("local P = \"%b(\"\nP = P .. \"\"\nprint((\"abc\"):find(P))\n"),
    codes_of("local find = string.find\nprint(find(\"abc\", \"%b(\"))\n"),
    codes_of("local fmt = string.format\nprint(fmt(\"%d\", \"x\"))\n"),
    codes_of("local fmt = string.format\nfmt = string.format\nprint(fmt(\"%d\", \"x\"))\n"),
    -- the type of a format that is wrong is not told twice, a plain `find` has no captures, a pattern with none answers the match
    codes_of("local a, b, c = string.unpack(\"i4 y\", \"x\")\nprint(a, b, c)\n"),
    codes_of("local _, _, c = (\"abc\"):find(\"()\", 1, true)\nif c ~= nil then\n  local s: string = c\n  print(s)\nend\n"),
    codes_of("local m = (\"abc\"):match(\"b\")\nif m ~= nil then\n  print(m:upper())\nend\n"),
    codes_of("for w in (\"a b\"):gmatch(\"%a\") do\n  print(w:upper())\nend\n"),
    codes_of("local P = (\"%b(\")\nprint((\"abc\"):find(P))\n"),
    codes_of("print(string.format(\"%s %s\", 1, true))\n"),
    -- a tail that may be empty fills no conversion, whatever the conversion takes: Lua raises on a missing value, nil or not
    codes_of("local function g(...: string): string\n  return string.format(\"%s %s\", ...)\nend\nprint(g)\n"),
    codes_of("local function g(a: string, ...: string): string\n  return string.format(\"%s %s %s\", a, ...)\nend\nprint(g)\n"),
    codes_of("local function f(): string...\n  return\nend\nprint(string.format(\"%q\", f()))\n"),
    codes_of("local t: {string} = {}\nprint(string.format(\"%s\", table.unpack(t)))\n"),
    codes_of("local function g(...: any): string\n  return string.format(\"%s-%s\", select(2, ...))\nend\nprint(g)\n"),
    codes_of("local function g(...: integer): string\n  return string.pack(\"i4 i4\", ...)\nend\nprint(g)\n"),
    codes_of("local function g(...: any): string\n  return string.format(\"%s\", \"x\", ...)\nend\nprint(g)\n"),
    -- the library function by what it is: the table in a local, a text, a string key, a local that holds another
    codes_of("local str = string\nprint(str.format(\"%d\", \"x\"))\n"),
    codes_of("local str = string\nprint(str.find(\"abc\", \"%b(\"))\n"),
    codes_of("local fmt = string.format\nlocal fmt2 = fmt\nprint(fmt2(\"%d\", \"x\"))\n"),
    codes_of("print((\"x\").format(\"%d\", \"x\"))\n"),
    codes_of("local s = \"x\"\nprint(s.format(\"%d\", \"x\"))\n"),
    codes_of("print(string[\"format\"](\"%d\", \"x\"))\n"),
    codes_of("local record Finder\n  find: function(string, string): integer\nend\nlocal f: Finder = { find = function(a: string, b: string): integer return 1 end }\nprint(f.find(\"a\", \"(\"))\n"),
    codes_of("print(Matcher.find(\"a\", \"(\"))\n"),
  }
  local want = {
    "not_assignable", "not_assignable", "not_assignable", "not_assignable", "not_assignable", "not_assignable", "", "",
    "arity", "arity", "",
    "", "not_assignable", "not_assignable", "", "", "not_assignable", "",
    "not_assignable", "", "overload_none",
    "pattern_malformed", "pattern_malformed", "", "pattern_malformed", "not_assignable", "",
    "pack_malformed", "", "", "", "pattern_malformed", "",
    "nil_not_allowed", "nil_not_allowed", "nil_not_allowed", "nil_not_allowed", "nil_not_allowed", "nil_not_allowed", "",
    "not_assignable", "pattern_malformed", "not_assignable", "not_assignable", "not_assignable", "not_assignable", "", "",
  }
  assert(#said == #want)
  local wrong: mut {string} = {}
  for i, each in ipairs(want) do
    if said[i] ~= each then
      wrong[#wrong + 1] = tostring(i) .. ": " .. said[i] .. " (wanted " .. each .. ")"
    end
  end
  assert(#wrong == 0, table.concat(wrong, "; "))
end

local function test_a_value_refused_by_a_parameter_carries_the_call_and_an_assignment_carries_none()
  local r = Programs.run([[
local function put(a: string, n: integer): integer
  return n
end
local x = put("a", "b")
local s: string = 1
local a, n = ("x"):gsub("a", function(c: integer): string return "" end)
]])
  assert(#r.errors == 3, Programs.codes(r))
  local own, plain, library = assert(r.errors[1]), assert(r.errors[2]), assert(r.errors[3])
  local argument = own.argument
  assert(own.code == "not_assignable" and argument ~= nil and argument.callee == "put" and argument.position == 2 and
      argument.module == "", own.msg)
  assert(plain.code == "not_assignable" and plain.argument == nil, plain.msg)
  local method = library.argument
  assert(method ~= nil and method.position == 2 and has(method.callee, "gsub"), library.msg)
end

local function test_an_argument_of_a_function_read_from_a_declaration_names_the_module_that_declares_it()
  local r = Programs.run([[
local class C
  n: integer
end
function C.make(n: integer): integer
  return n
end
local x = C.make("s")
local y = ("x"):sub("a")
local z = C.make("s")
]])
  assert(#r.errors == 3, Programs.codes(r))
  local statics, method = assert(r.errors[1]), assert(r.errors[2])
  local again = assert(r.errors[3])
  local a, b, c = statics.argument, method.argument, again.argument
  assert(a ~= nil and b ~= nil and c ~= nil, Programs.codes(r))
  assert(a.module ~= "" and a.module == c.module and a.callee == "C.make", a.module)
  -- the module of the callee is the one read last: another call between the two does not leave its module behind
  assert(b.callee:find("sub", 1, true) ~= nil and b.module ~= a.module, b.module)
end

local function test_an_argument_of_a_call_inside_an_argument_keeps_the_module_of_its_own_call()
  local r = Programs.run([[
local class C
  n: integer
end
function C.make(n: integer, m: integer): integer
  return n
end
local function id(n: integer): integer
  return n
end
local x = C.make(id(1), "s")
]])
  assert(#r.errors == 1, Programs.codes(r))
  local argument = assert(r.errors[1]).argument
  assert(argument ~= nil and argument.callee == "C.make" and argument.module ~= "" and argument.position == 2, Programs.codes(r))
end

local function test_the_marker_of_an_argument_does_not_outlast_the_call_it_belongs_to()
  local r = Programs.run([[
local function id(n: integer): integer
  return n
end
local x = id("s")
local y: string = id(1)
]])
  assert(#r.errors == 2, Programs.codes(r))
  local call, assignment = assert(r.errors[1]), assert(r.errors[2])
  assert(call.argument ~= nil and assignment.argument == nil, Programs.codes(r))
end
