--- The code generator ([`lang.codegen`]) against the fork's. Each case is a piece of Teal: the fork compiles
--- it ([`build.compile`]'s `lua`, with no module served), and the generator writes the Lua of what
--- [`lang.translate`] makes of it. The two texts are equal, line for line, once the layout of a `continue` is set
--- aside ([`lang.codegen`]'s `compared`). The cases are the constructs the plan classes as respellings and
--- layout, the statements and expressions of Lua, and the places the fork puts a line break or an indent. A
--- case of a meaning or a new construct (`match`, `class`) is run or refused instead.

local Ast = require("lang.ast")
local Codegen = require("lang.codegen")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local compile = require("build.compile")
local teal = require("build.teal")
local type compiler = require("build.compiler")

Test.policy{}

local held: {compiler} = {}

--- The compiler this binary carries, without its line information, loaded once.
local function fork(): compiler
  if held[1] == nil then
    held[1] = assert(teal.load(true))
  end
  return held[1]
end

--- The generator's result for `text`, which is in the new grammar. `truthy` is what it takes as neither false nor nil.
local function generated(text: string, truthy?: function(e: Ast.Exp): boolean): Codegen.Generated
  local parsed = Parser.parse(Lexer.lex(text, "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0, parsed.errors[1] ~= nil and parsed.errors[1].msg .. "\n" .. text or "")
  return Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, "t.tl", {}), truthy)
end

--- Asserts the generator writes the fork's Lua for the Teal `lines`.
local function same(...: string)
  local source = table.concat({ ... }, "\n") .. "\n"
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, made.errors[1] ~= nil and made.errors[1].msg .. "\n" .. made.text or "")
  -- The translator writes an `if` expression only where the value is never false, which is what it tells the generator.
  local ours = generated(made.text, Translate.never_false)
  assert(#ours.errors == 0, ours.errors[1] ~= nil and ours.errors[1].msg or "")
  local theirs = assert(compile.lua(fork(), "t.tl", source))
  assert(Codegen.compared(ours.text) == Codegen.compared(theirs),
    "the generator wrote\n" .. ours.text .. "\nthe fork wrote\n" .. theirs)
end

--- Runs the generator's text of `source` and answers the four values it returns.
local function run(source: string, truthy?: function(e: Ast.Exp): boolean): any, any, any, any
  local result = generated(source, truthy)
  assert(#result.errors == 0, result.errors[1] ~= nil and result.errors[1].msg or "")
  local env: {string: any} = { print = print, pcall = pcall, error = error, select = select, table = table, math = math,
    type = type, ipairs = ipairs, pairs = pairs }
  local chunk = assert(load(result.text, "=t", "t", env))
  return chunk()
end

--- Runs the Teal `source`, after the translator.
local function run_teal(source: string): any, any, any, any
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, made.errors[1] ~= nil and made.errors[1].msg or "")
  return run(made.text, Translate.never_false)
end

--- Lines as one source.
local function program(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

-- statements ----------------------------------------------------------------------------------------------------

local function test_a_local_with_attributes_and_an_assignment_of_several_values()
  same(
    "local a, b = 1, \"two\"",
    "local c <const> = 3",
    "local d <close> = nil",
    "a, b = b, a",
    "return a, b, c")
end

local function test_a_local_and_a_function_with_typed_parameters_and_returns()
  same(
    "local function add(a: integer, b?: integer): integer",
    "  return a + (b or 0)",
    "end",
    "local rest = function(first: string, ...: any): string",
    "  return first",
    "end",
    "return add, rest")
end

local function test_a_function_of_a_record_and_a_call_of_it()
  same(
    "local record Counter",
    "  n: integer",
    "end",
    "function Counter.make(): Counter",
    "  return { n = 0 }",
    "end",
    "local c = Counter.make()",
    "c.n = c.n + 1",
    "return c")
end

local function test_if_elseif_else_while_repeat_and_both_for_loops()
  same(
    "local n = 0",
    "if n == 0 then",
    "  n = 1",
    "elseif n == 1 then",
    "  n = 2",
    "else",
    "  n = 3",
    "end",
    "while n < 10 do n = n + 1 end",
    "repeat",
    "  n = n - 1",
    "until n < 5",
    "for i = 1, 10, 2 do",
    "  n = n + i",
    "end",
    "for k, v in pairs({ a = 1 }) do",
    "  n = n + v",
    "end",
    "do",
    "  local inner = n",
    "  n = inner",
    "end",
    "return n")
end

local function test_break_and_return_in_the_middle_of_a_loop()
  same(
    "local function find(items: {string}, wanted: string): integer",
    "  for i = 1, #items do",
    "    if items[i] == wanted then",
    "      return i",
    "    end",
    "    if i > 100 then break end",
    "  end",
    "  return 0",
    "end",
    "return find")
end

local function test_statements_on_one_line_are_separated_by_a_semicolon()
  same("local a = 1 local b = 2 a = b print(a)")
end

local function test_a_statement_that_begins_with_a_parenthesis_ends_the_one_before_with_a_semicolon()
  same(
    "local f = print",
    "local g = f",
    "(g or f)(1)")
end

local function test_blank_lines_and_comments_keep_every_statement_on_its_line()
  same(
    "-- a comment",
    "",
    "",
    "local a = 1 -- another",
    "--[[ a long",
    "comment ]]",
    "",
    "local b = 2",
    "return a + b")
end

-- continue ------------------------------------------------------------------------------------------------------

local function test_continue_is_a_goto_to_a_label_on_the_line_of_the_end()
  same(
    "for i = 1, 3 do",
    "  if i == 2 then goto continue end",
    "  print(i)",
    "  ::continue::",
    "end")
  local made = Translate.translate("for i = 1, 3 do\n  if i == 2 then goto continue end\n  print(i)\n  ::continue::\nend\n", "t.tl")
  assert(generated(made.text).text == "for i = 1, 3 do\n   if i == 2 then goto continue end\n   print(i)\n\n::continue:: end",
    generated(made.text).text)
end

local function test_continue_in_nested_loops_and_in_a_repeat()
  same(
    "local n = 0",
    "while n < 5 do",
    "  n = n + 1",
    "  for j = 1, 3 do",
    "    if j == 1 then goto continue end",
    "    print(j)",
    "    ::continue::",
    "  end",
    "  if n == 2 then goto continue end",
    "  print(n)",
    "  ::continue::",
    "end",
    "repeat",
    "  n = n - 1",
    "  if n == 3 then goto continue end",
    "  print(n)",
    "  ::continue::",
    "until n < 1")
end

local function test_a_loop_with_no_continue_has_no_label_and_a_function_in_a_loop_keeps_its_own()
  same(
    "for i = 1, 3 do",
    "  local f = function()",
    "    for j = 1, 2 do",
    "      if j == 1 then goto continue end",
    "      print(j)",
    "      ::continue::",
    "    end",
    "  end",
    "  f()",
    "end")
end

-- expressions ---------------------------------------------------------------------------------------------------

local function test_every_binary_and_unary_operator()
  same(
    "local a, b = 7, 2",
    "local t = {",
    "  a + b, a - b, a * b, a / b, a // b, a % b, a ^ b, a .. b,",
    "  a == b, a ~= b, a < b, a > b, a <= b, a >= b,",
    "  a & b, a | b, a ~ b, a << b, a >> b,",
    "  a and b, a or b, not a, -a, #\"s\", ~a,",
    "}",
    "return t")
end

local function test_parentheses_stay_and_a_looser_operand_under_a_tighter_operator_gets_them()
  same(
    "local a, b, c = 1, 2, 3",
    "local t = { (a + b) * c, a + (b * c), (a or b) and c, a or (b and c), -(a + b), not (a == b), (a .. b) .. c, a .. (b .. c) }",
    "return t")
end

local function test_a_double_minus_does_not_begin_a_comment()
  -- The fork writes `--a` here, and the rest of the line is a comment; so the generator is run, not compared.
  local source = "local a = 3\nreturn - -a, - (-a), -a - -a\n"
  local text = generated(source).text
  assert(text:find("--", 1, true) == nil, text)
  local x, y, z = run(source)
  assert(x == 3 and y == 3 and z == 0, text)
end

local function test_calls_method_calls_fields_and_indexes()
  same(
    "local s = \"abc\"",
    "local t = { items = { 1, 2 }, name = \"n\" }",
    "local n = #t.items + t.items[1] + t[\"items\"][2]",
    "local u = (s):upper():lower()",
    "local v = s:sub(1, 2):rep(3)",
    "print(n, u, v, t.name:len(), select(\"#\", 1, 2))",
    "t.items[#t.items + 1] = 3",
    "return t")
end

local function test_a_call_with_a_table_argument_and_a_chain_of_calls()
  same(
    "local function f(t: {string: integer}): function(): integer",
    "  return function(): integer return t.x end",
    "end",
    "local v = f{ x = 1 }()",
    "return v")
end

local function test_string_literals_in_every_form()
  same(
    "local a = \"double \\\"q\\\" \\n\"",
    "local b = 'single \\'q\\' \\x41 \\u{48} \\065'",
    "local c = [[long",
    "string]]",
    "local d = [==[with ]] inside]==]",
    "local t = { [ [[k]] ] = 1 }",
    "return a, b, c, d, t[ [[k]] ]")
end

local function test_number_literals_in_every_form()
  same(
    "local t = { 0, 12, 0x10, 0xFF, 1.5, .5, 3., 1e3, 1E-2, 2.5e+1, 1_000, 0x1_0 }",
    "return t")
end

local function test_a_vararg_and_a_function_that_returns_several_values()
  same(
    "local function pack(...: any): {any}",
    "  return { ... }",
    "end",
    "local function two(): integer, string",
    "  return 1, \"a\"",
    "end",
    "local a, b = two()",
    "return pack(a, b, ...)")
end

-- tables --------------------------------------------------------------------------------------------------------

local function test_table_constructors_of_every_item_form()
  same(
    "local t = { 1, 2, x = 3, [\"y z\"] = 4, [1 + 1] = 5, nested = { a = { 1 }, b = {} }, f = function() end }",
    "return t")
end

local function test_a_table_that_spans_lines_gets_a_trailing_comma_and_an_indent()
  same(
    "local t = {",
    "  a = 1,",
    "  b = {",
    "    c = 2,",
    "  },",
    "  d = { 1, 2,",
    "    3 },",
    "}",
    "return t")
end

local function test_a_semicolon_between_table_items_is_a_comma()
  same("local t = { 1; 2; x = 3; }", "return t")
end

local function test_a_table_in_a_call_that_spans_lines()
  same(
    "local function f(a: any, b: any) end",
    "f({",
    "  x = 1,",
    "}, {",
    "  y = 2,",
    "})")
end

-- layout --------------------------------------------------------------------------------------------------------

local function test_an_expression_that_breaks_across_lines_keeps_its_breaks_and_indents()
  same(
    "local function f(a: integer, b: integer): integer",
    "  local total = a +",
    "    b *",
    "    2",
    "  local s = \"x\"",
    "    .. \"y\"",
    "  return total,",
    "    #s",
    "end",
    "return f")
end

local function test_a_call_whose_arguments_span_lines()
  same(
    "local function f(...: any): any return ... end",
    "local r = f(1,",
    "  2,",
    "  f(3,",
    "    4),",
    "  function()",
    "    return 5",
    "  end)",
    "return r")
end

local function test_functions_nested_in_functions_and_blocks_on_one_line()
  same(
    "local function outer()",
    "  local function inner()",
    "    if true then return function() return 1 end end",
    "    while false do end",
    "    return nil",
    "  end",
    "  return inner",
    "end",
    "return outer")
end

local function test_an_empty_function_body_and_an_empty_block()
  same(
    "local f = function() end",
    "local g = function()",
    "end",
    "if f then end",
    "while false do",
    "end",
    "do end",
    "return g")
end

-- types are erased ------------------------------------------------------------------------------------------------

local function test_an_optional_a_union_and_a_function_type_write_nothing()
  same(
    "local a: string | nil = nil",
    "local b: nil | integer = 1",
    "local c: string | integer | nil = \"s\"",
    "local d: function(? integer, string...): string | nil",
    "local e: {string: {integer}} = {}",
    "return a, b, c, d, e")
end

local function test_a_cast_writes_only_its_value()
  same(
    "local x: any = 1",
    "local n = x as integer",
    "local m = (x as any) as number",
    "return n, m, x as string")
end

local function test_a_record_with_a_readonly_field_and_a_closing_metamethod_writes_nothing_unused()
  same(
    "local record Box",
    "  readonly size: integer",
    "  metamethod __close: function(Box)",
    "end",
    "local function open(): Box return { size = 1 } end",
    "return open")
end

local function test_a_record_used_as_a_value_is_a_table_of_its_nested_records()
  same(
    "local record Outer",
    "  record Inner",
    "    record Deep",
    "    end",
    "    x: integer",
    "  end",
    "  enum Kind",
    "    \"a\"",
    "  end",
    "  interface Face",
    "    y: integer",
    "  end",
    "  record Other",
    "  end",
    "end",
    "function Outer.f() end",
    "return Outer")
end

local function test_a_generic_record_used_as_a_value_is_an_empty_table()
  same(
    "local record Stack<T>",
    "  items: {T}",
    "  record Entry",
    "  end",
    "end",
    "return Stack")
end

local function test_enums_interfaces_and_aliases_write_nothing()
  same(
    "local enum Color",
    "  \"red\"",
    "end",
    "local interface Shape",
    "  area: function(Shape): number",
    "end",
    "local type Alias = string",
    "local type Colors = {Color}",
    "local c: Color = \"red\"",
    "return c")
end

local function test_a_type_import_is_a_require_unless_it_is_used_only_as_a_type()
  same(
    "local type Fs = require(\"cosmic.fs\")",
    "local type Json = require(\"cosmic.json\")",
    "local type Unused = require(\"cosmic.hash\")",
    "local a: Json.Value = nil",
    "return Fs.read, a")
end

local function test_a_record_the_program_names_only_in_types_is_not_written()
  same(
    "local record Point",
    "  x: integer",
    "end",
    "local function origin(): Point return { x = 0 } end",
    "local p: Point = origin()",
    "return p")
end

-- is ----------------------------------------------------------------------------------------------------------------

local function test_is_of_every_primitive_and_of_nil_and_a_function_type()
  same(
    "local x: any = 1",
    "local t = {",
    "  x is string, x is integer, x is number, x is boolean, x is nil, x is thread,",
    "  x is {string}, x is {string: integer},",
    "}",
    "local f = x is function(): integer",
    "return t, f")
end

local function test_is_of_a_local_enum_a_local_record_and_an_alias_of_either()
  same(
    "local enum Color",
    "  \"red\"",
    "end",
    "local record Point",
    "  x: integer",
    "end",
    "local type Shade = Color",
    "local type Maybe = {Point}",
    "local type Fn = function(): integer",
    "local record Holder",
    "  type Inner = Color",
    "  type Callback = function()",
    "  record Rec",
    "  end",
    "end",
    "local x: any = nil",
    "return { x is Color, x is Point, x is Shade, x is Maybe, x is Fn, x is Holder.Inner,",
    "  x is Holder.Callback, x is Holder.Rec, x is Stream.Reader }")
end

local function test_is_under_not_and_other_operators_gets_the_parentheses_the_fork_writes()
  same(
    "local x: any = 1",
    "return not x is string, (x is string) == true, x is integer and x is number")
end

local function test_is_of_an_alias_of_a_union_is_a_test_for_each_member()
  same(
    "local record Point",
    "  x: integer",
    "end",
    "local enum Color",
    "  \"red\"",
    "end",
    "local type Scalar = string | integer",
    "local type Maybe = Point | nil",
    "local x: any = nil",
    "local y = { x }",
    "return x is Scalar, x is Maybe, not x is Scalar, x is Scalar and x is Maybe, y[1] == x,",
    "  x is",
    "  Scalar")
end

--- The fork writes a test for a table where a member of the union is itself a named type, an enum among them,
--- which is no Lua for the value it tests; the generator writes the test of what the name stands for.
local function test_is_of_a_union_of_named_types_tests_what_each_stands_for()
  local source = table.concat({
    "local enum Color",
    "  \"red\"",
    "end",
    "local type Scalar = string | integer",
    "local type Either = Scalar | boolean | Color",
    "local x: any = nil",
    "return x is Either",
  }, "\n") .. "\n"
  local text = generated(source).text
  local last = text:match("return (.*)$")
  assert(last == "type(x) == \"string\" or math.type(x) == \"integer\" or type(x) == \"boolean\" or " ..
      "type(x) == \"string\"", text)
end

local function test_a_test_with_its_type_on_another_line_is_still_lua()
  -- The fork breaks the line inside the quotes of the type.
  local source = "local x: any = 1\nlocal ok = x\n  is string\nlocal after = 1\nreturn ok\n"
  local text = generated(source).text
  assert(text == "local x = 1\nlocal ok = x\n  type(x) == \"string\"\nlocal after = 1\nreturn ok" or
      load(text, "=t", "t") ~= nil, text)
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[4] == "local after = 1", text)
  assert(load(text, "=t", "t", {}) ~= nil, text)
end

local function test_is_as_a_condition_and_across_a_line_break()
  same(
    "local function f(x: any): string",
    "  if x is string then",
    "    return x",
    "  elseif x is integer",
    "    or x is number then",
    "    return \"n\"",
    "  end",
    "  return \"\"",
    "end",
    "return f")
end

-- if expressions -------------------------------------------------------------------------------------------------

local function test_a_ternary_of_a_literal_is_an_if_expression_and_writes_and_or()
  same(
    "local n = 3",
    "local a = n > 1 and \"many\" or \"few\"",
    "local b = n == 1 and 1 or n == 2 and 2 or 3",
    "local c = (n > 1 and { n } or {}) .. \"\"",
    "return a, b, c")
end

local function test_a_ternary_whose_middle_may_be_false_stays_as_it_is()
  same(
    "local f = print",
    "local n = f and f(1) or 2",
    "return n")
end

local function test_an_if_expression_that_spans_lines()
  same(
    "local n = 3",
    "local a = n > 1",
    "  and \"many\"",
    "  or \"few\"",
    "return a")
end

-- the new constructs ---------------------------------------------------------------------------------------------

local function test_a_match_runs_the_arm_of_its_pattern_and_binds_the_rest()
  local source = table.concat({
    "local function f(ok: boolean): boolean, string",
    "  return ok, \"value\"",
    "end",
    "local function g(ok: boolean): string",
    "  match f(ok) do",
    "  | (true, v) then",
    "    return \"yes \" .. v",
    "  | (false, e) then",
    "    return \"no \" .. e",
    "  end",
    "end",
    "return g(true), g(false)",
  }, "\n") .. "\n"
  local first, second = run(source)
  assert(first == "yes value" and second == "no value", tostring(first) .. " " .. tostring(second))
end

local function test_a_match_keeps_every_statement_on_its_line()
  local source = table.concat({
    "local function f(): boolean, integer return true, 1 end",
    "match f() do",
    "| (true, n) then",
    "  print(n)",
    "| (false, m) then",
    "  print(m)",
    "end",
    "local after = 1",
  }, "\n") .. "\n"
  local lines: {string} = {}
  for line in (generated(source).text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  assert(lines[8] == "local after = 1" and lines[4]:find("print(n)", 1, true) and lines[6]:find("print(m)", 1, true),
    table.concat(lines, "\n"))
end

local function test_nested_matches_do_not_share_their_temporaries()
  local source = table.concat({
    "local function f(a: boolean, b: boolean): boolean, boolean return a, b end",
    "local function g(a: boolean, b: boolean): string",
    "  match f(a, b) do",
    "  | (true, x) then",
    "    match f(x, a) do",
    "    | (true, y) then return \"tt\"",
    "    | (false, z) then return \"tf\"",
    "    end",
    "  | (false, w) then",
    "    return \"f\"",
    "  end",
    "  return \"?\"",
    "end",
    "return g(true, true), g(true, false), g(false, true)",
  }, "\n") .. "\n"
  local text = generated(source).text
  local a, b, c = run(source)
  assert(a == "tt" and b == "tf" and c == "f", text)
end

local function test_a_protected_call_is_an_ordinary_call()
  local source = "local ok, err = pcall(function() error(\"x\", 0) end)\nreturn ok, err\n"
  local ok, err = run(source)
  assert(ok == false and err == "x")
end

local function test_a_class_is_refused_with_the_line_it_is_on()
  local result = generated("local x = 1\nlocal class Counter\n  n: integer\n  function bump(self)\n    self.n = self.n + 1\n  end\nend\nreturn x\n")
  assert(#result.errors == 1, #result.errors)
  local e = result.errors[1]
  assert(e.code == "class_refused" and e.y == 2 and e.x == 1, e.code .. " " .. e.y .. ":" .. e.x)
  assert(e.msg:find("Counter", 1, true) and e.fix ~= "")
  assert(result.text == "local x = 1\n\n\n\n\n\n\nreturn x", result.text)
end

local function test_an_is_of_a_class_is_refused()
  local result = generated("local class C\n  n: integer\nend\nlocal x: any = nil\nreturn x is C\n")
  local codes: {string} = {}
  for _, e in ipairs(result.errors) do
    codes[#codes + 1] = e.code
  end
  table.sort(codes)
  assert(table.concat(codes, " ") == "class_refused class_test_refused", table.concat(codes, " "))
end

local function test_the_generator_is_a_function_of_its_tree()
  local text = "local a = 1\nlocal function f(x: any): boolean\n  return x is string\nend\nreturn f(a)\n"
  assert(generated(text).text == generated(text).text)
end

-- if expressions that run -----------------------------------------------------------------------------------------

local function test_an_if_expression_with_a_false_or_nil_value_gives_it()
  local source = program(
    "local function pick(c: boolean, a: any, b: any): any",
    "  return if c then a else b end",
    "end",
    "return pick(true, false, 1), pick(true, nil, 1), pick(false, 2, 3), pick(true, 4, 5)")
  local a, b, c, d = run(source)
  assert(a == false and b == nil and c == 3 and d == 4, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
end

local function test_an_if_expression_does_not_evaluate_the_value_it_does_not_choose()
  local source = program(
    "local n = 0",
    "local function side(): integer",
    "  n = n + 1",
    "  return n",
    "end",
    "local x = if true then false else side() end",
    "local y = if false then 1 else side() end",
    "local z = if true then 1 else side() end",
    "return x, y, z, n")
  local x, y, z, n = run(source)
  assert(x == false and y == 1 and z == 1 and n == 1, tostring(x) .. " " .. tostring(y) .. " " .. tostring(z) .. " " .. tostring(n))
end

local function test_an_if_expression_with_several_arms_takes_the_first_arm_that_holds_even_when_it_is_false()
  local source = program(
    "local function pick(a: any, b: any, c: any, x: any, y: any, z: any): any",
    "  return if a then x elseif b then y elseif c then z else 0 end",
    "end",
    "return pick(false, true, true, 1, false, 3), pick(false, false, true, 1, false, 3), pick(false, false, false, 1, 2, 3), pick(true, 1, 1, nil, 2, 3)")
  local a, b, c, d = run(source)
  assert(a == false and b == 3 and c == 0 and d == nil, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
end

local function test_an_if_expression_gives_one_value_and_passes_the_varargs_of_its_function_on()
  local source = program(
    "local function two(): integer, integer return 1, 2 end",
    "local function count(...: any): integer return select(\"#\", ...) end",
    "local function first(...: any): any",
    "  return if select(\"#\", ...) > 0 then ... else 0 end",
    "end",
    "return count(if true then two() else 0 end), first(false), first(), first(7, 8)")
  local a, b, c, d = run(source)
  assert(a == 1 and b == false and c == 0 and d == 7, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
end

local function test_an_if_expression_whose_values_are_never_false_is_and_or_and_keeps_its_guards()
  local source = program(
    "local function pick(a: any, b: any): integer",
    "  return if a or b then 1 else 2 end",
    "end",
    "local function arm(c: any, x: any, y: any): any",
    "  return if c then x or y else 9 end",
    "end",
    "return pick(true, false), pick(false, false), arm(false, 1, 5), arm(true, nil, 5)")
  local always: function(e: Ast.Exp): boolean = function(_e: Ast.Exp): boolean return true end
  local a, b, c, d = run(source, always)
  assert(a == 1 and b == 2 and c == 9 and d == 5, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
  local text = generated(source, always).text
  assert(text:find("(a or b) and 1 or 2", 1, true) and text:find("c and (x or y) or 9", 1, true), text)
  -- Left to the syntax, a value that may be false is no `and`/`or`; an arithmetic is.
  assert(not generated("local x = if y then z else 2 end\n").text:find(" and ", 1, true))
  assert(generated("local x = if y then z + 1 else 2 end\n").text:find("y and z + 1 or 2", 1, true))
  assert(generated("local x = if y then false else 2 end\n").text:find("function", 1, true))
end

-- continue that run -------------------------------------------------------------------------------------------------

local function test_a_loop_that_ends_in_a_return_after_a_continue_keeps_its_label_valid()
  local source = program(
    "local function from_for(): integer",
    "  for i = 1, 5 do",
    "    if i < 3 then continue end",
    "    return i",
    "  end",
    "  return 0",
    "end",
    "local function from_while(): integer",
    "  local i = 0",
    "  while true do",
    "    i = i + 1",
    "    if i < 3 then continue end",
    "    return i * 10",
    "  end",
    "end",
    "local function from_repeat(): integer",
    "  local i = 0",
    "  repeat",
    "    i = i + 1",
    "    if i < 3 then continue end",
    "    return i * 100",
    "  until false",
    "end",
    "return from_for(), from_while(), from_repeat()")
  local a, b, c = run(source)
  assert(a == 3 and b == 30 and c == 300, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c))
  assert(generated(source).text:find("do return i end", 1, true))
end

local function test_continue_in_nested_loops_jumps_to_the_loop_it_is_in()
  local source = program(
    "local out: {string} = {}",
    "for i = 1, 3 do",
    "  for j = 1, 3 do",
    "    if j == 2 then continue end",
    "    out[#out + 1] = tostring(i * 10 + j)",
    "  end",
    "  if i == 2 then continue end",
    "  out[#out + 1] = tostring(i)",
    "end",
    "return table.concat(out, \",\")")
  local text = generated(source).text
  local env: {string: any} = { table = table, tostring = tostring }
  local chunk = assert(load(text, "=t", "t", env))
  assert(chunk() == "11,13,1,21,23,31,33,3", text)
end

local function test_continue_in_a_repeat_and_in_a_while_with_a_loop_inside_runs_its_pass()
  local source = program(
    "local n, s = 0, 0",
    "repeat",
    "  n = n + 1",
    "  if n % 2 == 0 then continue end",
    "  s = s + n",
    "until n >= 5",
    "local w, c = 0, 0",
    "while w < 4 do",
    "  w = w + 1",
    "  for k = 1, 2 do",
    "    if k == 1 then continue end",
    "    c = c + 1",
    "  end",
    "  if w == 2 then continue end",
    "  c = c + 10",
    "end",
    "return s, c")
  local s, c = run(source)
  assert(s == 9 and c == 34, tostring(s) .. " " .. tostring(c))
end

-- names Lua 5.5 reserves ---------------------------------------------------------------------------------------------

local function test_goto_and_global_name_fields_keys_and_functions_without_being_words_of_lua()
  local source = program(
    "local t = { goto = 1, global = 2, [\"end\"] = 3 }",
    "t.goto = t.goto + 10",
    "local R = {}",
    "function R.goto(x: integer): integer",
    "  return x + 1",
    "end",
    "function R.global(): string return \"g\" end",
    "(print)(1)",
    "return t.goto + t.global, R.goto(1), R.global(), t[\"end\"]")
  local a, b, c, d = run(source)
  assert(a == 13 and b == 2 and c == "g" and d == 3, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
  local text = generated(source).text
  assert(text:find("[\"goto\"] = 1", 1, true) and text:find("t[\"goto\"] = t[\"goto\"] + 10", 1, true) and
      text:find("R[\"goto\"] = function(x)", 1, true) and text:find("end;\n(print)(1)", 1, true), text)
end

-- tests ---------------------------------------------------------------------------------------------------------

local function test_a_test_under_a_comparison_is_in_parentheses()
  local source = program(
    "local a, b: any, any = true, \"s\"",
    "return a == b is string, b is string == a, a ~= b is string, b is integer == false")
  local w, x, y, z = run(source)
  assert(w == true and x == true and y == false and z == true, tostring(w) .. " " .. tostring(x) .. " " .. tostring(y) .. " " .. tostring(z))
end

local function test_a_union_alias_tested_on_a_value_that_is_no_name_evaluates_the_value_once()
  local source = program(
    "local type NumOrStr = number | string",
    "local type MaybeS = string?",
    "local h = { f = 1 }",
    "local n = 0",
    "local function get(): any",
    "  n = n + 1",
    "  return \"x\"",
    "end",
    "local function none(): any return nil end",
    "return h.f is NumOrStr, get() is MaybeS, none() is MaybeS, n")
  local a, b, c, n = run(source)
  assert(a == true and b == true and c == true and n == 1, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(n))
end

local function test_an_alias_of_integer_true_or_false_tests_for_that()
  local source = program(
    "local type Int = integer",
    "local type Yes = true",
    "local type No = false",
    "local function f(x: any): boolean, boolean, boolean, boolean",
    "  return x is Int, x is Yes, x is No, x is Int and x is Int",
    "end",
    "local a, b, c, d = f(2)",
    "local e, g, h = f(1.5)",
    "local i, j, k = f(true)",
    "local l, m, n = f(false)",
    "return a == true and b == false and d == true and e == false and g == false and h == false and i == false and j == true",
    "  and k == false and l == false and m == false and n == true")
  assert(run(source) == true)
end

local function test_a_table_key_that_begins_with_a_long_string_is_spaced()
  local source = program(
    "local x = \"k\"",
    "local t = { [ [[a]] .. x ] = 1, [ [[b]] ] = 2 }",
    "return t.ak, t.b, t[ [[b]] ]")
  local a, b, c = run(source)
  assert(a == 1 and b == 2 and c == 2, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c))
end

-- the fork's reading of a power -------------------------------------------------------------------------------------

local function test_a_unary_operator_over_a_power_is_the_forks_reading_once_translated()
  same(
    "local a = 2",
    "local t = { -a ^ 2, #\"abc\" ^ 2, a ^ -a ^ 2, -(a ^ 2), (-a) ^ 2 }",
    "return t")
  local a, b, c, d = run_teal(program("local a = 2", "return -a ^ 2, - -a ^ 2, a ^ -a ^ 2, -(a ^ 2)"))
  assert(a == 4 and b == 4 and c == 16 and d == -4, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
end

-- survivors -------------------------------------------------------------------------------------------------------

local function test_the_arguments_of_a_call_whose_table_is_on_a_line_of_its_own_keep_its_line()
  same(
    "local s = { rep = print }",
    "local r = s:rep",
    "{ 2 }",
    "local function f(t: {integer}): integer return #t end",
    "local p = f",
    "{ 1,",
    "  2 }",
    "local o = f",
    "{",
    "  1 }",
    "return r, p, o")
end
