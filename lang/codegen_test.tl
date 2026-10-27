--- The code generator ([`lang.codegen`]) against the fork's. Each case is a piece of Teal: the Lua the fork wrote of
--- it is kept as text ([`lang.forked`], [`testdata/forked/codegen.txt`]), and the generator writes the Lua of what
--- [`lang.translate`] makes of it. The two texts are equal, line for line, once the layout of a `continue` is set
--- aside ([`lang.codegen`]'s `compared`). The cases are the constructs the plan classes as respellings and
--- layout, the statements and expressions of Lua, and the places the fork puts a line break or an indent. A
--- case of a meaning or a new construct (`match`, `class`) is run or refused instead.

local Ast = require("lang.ast")
local BoundaryChecks = require("lang.boundary_checks")
local Codegen = require("lang.codegen")
local Forked = require("lang.forked")
local Programs = require("lang.check_programs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local Truthy = require("lang.truthy")

Test.policy{ grants = { { path = "testdata/forked/codegen.txt", letters = "r" } } }

--- What the fork wrote of each program, recorded from the tool of main before the switch ([`lang.forked`]).
local record Held
  mut kept: {string: Forked.Said}?
end

local held: Held = { kept = nil }

local function forked(): {string: Forked.Said}
  local kept = held.kept
  if kept == nil then
    kept = Forked.load("testdata/forked/codegen.txt")
    held.kept = kept
  end
  return kept
end

--- The Lua the fork wrote of `source`, compiled alone, as the file records it.
local function fork_wrote(source: string): string
  local said = Forked.said(forked(), source)
  assert(said.known, "no text of the fork's Lua is kept for:\n" .. source)
  return (assert(said.text, "the fork refused:\n" .. source))
end

--- The generator's result for `text`, which is in the new grammar. `truthy` is what it takes as neither false nor nil.
local function generated(text: string, truthy?: function(e: Ast.Exp): boolean): Codegen.Generated
  local parsed = Parser.parse(Lexer.lex(text, "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0, if parsed.errors[1] ~= nil then parsed.errors[1].msg .. "\n" .. text else "" end)
  return Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, "t.tl", {}), truthy)
end

--- Asserts the generator writes the fork's Lua for the Teal `lines`.
local function same(...: string)
  local source = table.concat({ ... }, "\n") .. "\n"
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, if made.errors[1] ~= nil then made.errors[1].msg .. "\n" .. made.text else "" end)
  -- The translator writes an `if` expression only where the value is never false, which is what it tells the generator.
  local ours = generated(made.text, Truthy.never_false)
  assert(#ours.errors == 0, if ours.errors[1] ~= nil then ours.errors[1].msg else "" end)
  local theirs = fork_wrote(source)
  assert(Codegen.compared(ours.text) == Codegen.compared(theirs),
    "the generator wrote\n" .. ours.text .. "\nthe fork wrote\n" .. theirs)
end

--- Runs the generator's text of `source` and answers the four values it returns.
local function run(source: string, truthy?: function(e: Ast.Exp): boolean): any, any, any, any
  local result = generated(source, truthy)
  assert(#result.errors == 0, if result.errors[1] ~= nil then result.errors[1].msg else "" end)
  local env: {string: any} = { print = print, pcall = pcall, error = error, select = select, table = table, math = math,
    type = type, ipairs = ipairs, pairs = pairs }
  local chunk = assert(load(result.text, "=t", "t", env))
  return chunk()
end

--- Runs the Teal `source`, after the translator.
local function run_teal(source: string): any, any, any, any
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, if made.errors[1] ~= nil then made.errors[1].msg else "" end)
  return run(made.text, Truthy.never_false)
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

local function test_a_method_call_on_an_enum_is_written_as_it_is_in_the_source()
  local source = program(
    "local enum Kind",
    "  \"a\"",
    "end",
    "local k: Kind = \"a\"",
    "local u = k:upper()",
    "return u .. k:rep(2) .. (k):lower()")
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, "the translator refused the program")
  local ours = generated(made.text, Truthy.never_false)
  assert(#ours.errors == 0, "the generator refused the program")
  for _, call in ipairs({ "k:upper()", "k:rep(2)", "(k):lower()" }) do
    assert(ours.text:find(call, 1, true) ~= nil, call .. " is not in\n" .. ours.text)
  end
  assert(run_teal(source) == "Aaaa")
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

local function test_a_build_that_serves_every_module_erases_an_import_it_never_reads_as_a_value()
  local text = table.concat({
    "local type Fs = require(\"cosmic.fs\")",
    "local type Unused = require(\"cosmic.hash\")",
    "local type _ = require(\"cosmic.child\")",
    "local type Json = require(\"cosmic.json\")",
    "local a: Json.Value = nil",
    "return Fs.read, a",
  }, "\n") .. "\n"
  local parsed = Parser.parse(Lexer.lex(text, "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0)
  local scoped = Scopes.build(parsed.chunk, "t.tl", {})
  local alone = Codegen.generate(parsed.chunk, scoped).text
  local served = Codegen.generate(parsed.chunk, scoped, nil, nil, nil, nil, nil, true).text
  assert(alone:find('local Unused = require("cosmic.hash")', 1, true), alone)
  assert(alone:find('local _ = require("cosmic.child")', 1, true), alone)
  assert(not served:find("cosmic.hash", 1, true) and not served:find("cosmic.child", 1, true), served)
  assert(served:find('local Fs = require("cosmic.fs")', 1, true), served)
  assert(not served:find("cosmic.json", 1, true), served)
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
  local lines: mut {string} = {}
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
  local lines: mut {string} = {}
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

-- classes ------------------------------------------------------------------------------------------------------

--- The generator's result for `source`, a program of one module checked as [`lang.check`] checks it, told which table
--- literals make a value of a class.
local function classed(source: string): Codegen.Generated
  local checked = Programs.run(source)
  -- The programs return what they run for the test to read, which a module does not declare.
  local codes = Programs.codes(checked):gsub("export_not_declared", ""):gsub("%s+", "")
  assert(#checked.before == 0 and codes == "", table.concat(checked.before, " ") .. " " .. codes .. " in\n" .. source)
  local names: mut {integer: string} = {}
  for id, decl in pairs(checked.result.literals) do
    names[id] = decl.name
  end
  return Codegen.generate(checked.chunk, checked.scoped, nil, names)
end

--- Runs the Lua of `classed(source)` and answers the five values it returns.
local function run_classes(source: string): any, any, any, any, any
  local result = classed(source)
  assert(#result.errors == 0, if result.errors[1] ~= nil then result.errors[1].msg else "" end)
  -- No `setmetatable` and no `getmetatable`: a class reaches the metatable through the reserved form alone.
  local env: {string: any} = { tostring = tostring, pcall = pcall, error = error, select = select, ipairs = ipairs }
  local chunk = assert(load(result.text, "=t", "t", env))
  return chunk()
end

local function test_a_class_is_its_method_table_and_a_literal_of_it_gets_that_table_as_its_metatable()
  local a, b, c, d = run_classes(program(
    "local class Counter",
    "  mut n: integer",
    "  function bump(self, by: integer): integer",
    "    self.n = self.n + by",
    "    return self.n",
    "  end",
    "  function get(self): integer",
    "    return self.n",
    "  end",
    "end",
    "function Counter.make(start: integer): Counter",
    "  return { n = start }",
    "end",
    "local c = Counter.make(10)",
    "local d: Counter = { n = 1 }",
    "return c:bump(5), c:get(), d:bump(1), c.n"))
  assert(a == 15 and b == 15 and c == 2 and d == 15, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c) .. " " .. tostring(d))
end

local function test_a_class_is_written_on_the_lines_of_its_source_and_a_literal_adds_its_class_to_its_line()
  local result = classed(program(
    "local class Box",
    "  n: integer",
    "  function get(self): integer",
    "    return self.n",
    "  end",
    "end",
    "local b: Box = {",
    "  n = 1,",
    "}",
    "return b:get()"))
  assert(result.text == program(
    "local Box = {}; Box.__index = Box",
    "",
    "function Box.get(self)",
    "   return self.n",
    "end",
    "",
    "local b = {",
    "   n = 1,",
    "} @ Box",
    "return b:get()"):sub(1, -2), result.text)
end

local function test_a_close_method_runs_at_the_end_of_the_block_of_a_close_local_in_the_reverse_order()
  local a, b = run_classes(program(
    "local record Out",
    "  mut text: string",
    "end",
    "local class Guard",
    "  out: Out",
    "  name: string",
    "  function __close(self)",
    "    self.out.text = self.out.text .. self.name .. \";\"",
    "  end",
    "end",
    "local out: Out = { text = \"\" }",
    "do",
    "  local first <close>: Guard = { out = out, name = \"first\" }",
    "  local second <close>: Guard = { out = out, name = \"second\" }",
    "  out.text = out.text .. \"body;\"",
    "end",
    "local after: Guard? = nil",
    "local last <close>: Guard? = after",
    "return out.text, last"))
  assert(a == "body;second;first;" and b == nil, tostring(a))
end

local function test_a_tostring_method_is_what_tostring_calls()
  local a, b = run_classes(program(
    "local class Point",
    "  x: integer",
    "  y: integer",
    "  function __tostring(self): string",
    "    return \"(\" .. tostring(self.x) .. \", \" .. tostring(self.y) .. \")\"",
    "  end",
    "end",
    "local p: Point = { x = 1, y = 2 }",
    "local q: Point = { x = 3, y = 4 }",
    "return tostring(p), tostring(q)"))
  assert(a == "(1, 2)" and b == "(3, 4)", tostring(a) .. tostring(b))
end

local function test_is_of_a_class_is_the_test_of_its_metatable()
  local a, b, c, d, e = run_classes(program(
    "local class A",
    "  n: integer",
    "end",
    "local class B",
    "  n: integer",
    "end",
    "local function kind(v: any): string",
    "  if v is A then return \"A\" end",
    "  if v is B then return \"B\" end",
    "  return \"other\"",
    "end",
    "local a: A = { n = 1 }",
    "local b: B = { n = 1 }",
    "return kind(a), kind(b), kind({ n = 1 }), kind(\"A\"), kind(nil)"))
  assert(a == "A" and b == "B" and c == "other" and d == "other" and e == "other", tostring(a) .. tostring(b) .. tostring(c) .. tostring(d) .. tostring(e))
end

local function test_a_class_test_is_written_as_the_metatable_compared_with_the_class_and_binds_looser_operands_in_parentheses()
  local result = classed(program(
    "local class C",
    "  n: integer",
    "end",
    "local function f(v: any, w: any): boolean",
    "  return v is C or (w is C and not (v is C))",
    "end",
    "local function g(v: C?): boolean",
    "  return v is C",
    "end",
    "return f, g"))
  assert(result.text:find("@v == C or (@w == C and not (@v == C))", 1, true) ~= nil, result.text)
  assert(result.text:find("return @v == C", 1, true) ~= nil, result.text)
end

local function test_a_literal_of_a_class_in_a_function_inside_a_method_is_written_with_the_class()
  local a, b = run_classes(program(
    "local class Cell",
    "  n: integer",
    "  function twice(self): Cell",
    "    local function build(): Cell",
    "      return { n = self.n * 2 }",
    "    end",
    "    return build()",
    "  end",
    "end",
    "local start: Cell = { n = 4 }",
    "return start:twice().n, start:twice():twice().n"))
  assert(a == 8 and b == 16)
end

local function test_a_class_in_a_block_is_written_as_a_local_of_the_block()
  local result = generated(program(
    "local function make(n: integer): integer",
    "  local class Cell",
    "    function twice(self): integer",
    "      return 2",
    "    end",
    "  end",
    "  return n",
    "end",
    "return make"))
  assert(#result.errors == 0 and result.text:find("   local Cell = {}; Cell.__index = Cell\n", 1, true) ~= nil, result.text)
end

local function test_a_generic_class_is_one_table_whatever_its_arguments()
  local a, b = run_classes(program(
    "local class Stack<T>",
    "  items: mut {T}",
    "  function push(self, v: T)",
    "    self.items[#self.items + 1] = v",
    "  end",
    "  function size(self): integer",
    "    return #self.items",
    "  end",
    "end",
    "local s: Stack<integer> = { items = {} }",
    "local t: Stack<string> = { items = {} }",
    "s:push(1)",
    "s:push(2)",
    "t:push(\"a\")",
    "return s:size(), t:size()"))
  assert(a == 2 and b == 1)
  local result = classed(program(
    "local class Stack<T>",
    "  items: mut {T}",
    "end",
    "local s: Stack<integer> = { items = {} }",
    "return s"))
  assert(result.text:find("local s = { items = {} } @ Stack", 1, true) ~= nil, result.text)
end

local function test_a_class_declared_inside_another_type_is_refused_where_it_is()
  local result = generated(program(
    "local record Outer",
    "  class Inner",
    "    n: integer",
    "  end",
    "end",
    "return Outer"))
  assert(#result.errors == 1 and result.errors[1].code == "class_nested_refused" and result.errors[1].y == 2,
    if #result.errors > 0 then result.errors[1].code else "none" end)
  assert(result.errors[1].msg:find("Inner", 1, true) and result.errors[1].fix ~= "")
  local deeper = generated(program(
    "local class Outer",
    "  record Middle",
    "    class Inner",
    "      n: integer",
    "    end",
    "  end",
    "end",
    "return Outer"))
  assert(#deeper.errors == 1 and deeper.errors[1].code == "class_nested_refused" and deeper.errors[1].y == 3)
end

local function test_a_program_cannot_write_the_reserved_form_of_the_virtual_machine()
  for _, source in ipairs({
      "local C = {}\nlocal v = {} @ C\nreturn v\n",
      "local C = {}\nlocal v = @C\nreturn v\n",
  }) do
    local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
    assert(#parsed.errors > 0, source)
  end
end

-- the class files against the fork's -----------------------------------------------------------------------------

--- The generator's Lua and the fork's for the Teal `source`, each apart from the classes of its translation.
local function apart_from_classes(source: string): string, string, Translate.Result
  local made = Translate.translate(source, "t.tl")
  assert(#made.errors == 0, if made.errors[1] ~= nil then made.errors[1].msg .. "\n" .. made.text else "" end)
  local parsed = Parser.parse(Lexer.lex(made.text, "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0)
  local ours = Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, "t.tl", {}), Truthy.never_false)
  assert(#ours.errors == 0)
  local theirs = fork_wrote(source)
  return Codegen.without_classes(ours.text, parsed.chunk), Codegen.fork_without_classes(theirs, parsed.chunk, made.metatables), made
end

local function test_a_file_with_a_class_is_the_forks_lua_apart_from_the_class_and_its_metatable()
  local ours, theirs, made = apart_from_classes(program(
    "local record Counter",
    "  n: integer",
    "  bump: function(Counter, integer): integer",
    "end",
    "",
    "local counter_mt: metatable<Counter> = { __index = Counter }",
    "",
    "function Counter:bump(by: integer): integer",
    "  self.n = self.n + by",
    "  return self.n",
    "end",
    "",
    "function Counter.make(start: integer): Counter",
    "  return setmetatable({ n = start, tag = \"(a, b)\" }, counter_mt)",
    "end",
    "",
    "local function twice(): integer",
    "  local c: Counter = setmetatable({",
    "    n = 1,",
    "  }, counter_mt)",
    "  return c:bump(1) + c:bump(1)",
    "end",
    "return twice"))
  assert(table.concat(made.metatables, " ") == "counter_mt", table.concat(made.metatables, " "))
  assert(ours == theirs, "ours\n" .. ours .. "\nfork's\n" .. theirs)
  -- What is compared is the statements around the class: the function with the constructors, and the statics.
  assert(ours:find("function Counter.make(start)", 1, true) ~= nil and ours:find("return twice", 1, true) ~= nil, ours)
  assert(ours:find("function Counter.bump", 1, true) == nil and ours:find("__index", 1, true) == nil,
    "the class is not compared: " .. ours)
end

local function test_a_metatable_that_stays_is_compared_with_its_calls()
  local ours, theirs, made = apart_from_classes(program(
    "local record Box",
    "  n: integer",
    "  get: function(Box): integer",
    "end",
    "local box_mt: metatable<Box> = { __index = Box }",
    "function Box:get(): integer",
    "  return self.n",
    "end",
    "local function adopt(t: {string: any}): Box",
    "  return setmetatable(t, box_mt)",
    "end",
    "return adopt"))
  assert(#made.metatables == 0)
  assert(ours == theirs and ours:find("local box_mt = { __index = Box }", 1, true) ~= nil and
      ours:find("return setmetatable(t, box_mt)", 1, true) ~= nil, ours .. "\n" .. theirs)
end

--- A metatable the translator removed had only calls on literals left, so the call of one is the literal.
local function test_the_fork_loses_a_setmetatable_call_only_of_a_metatable_the_translator_removed()
  local fork_lua = program(
    "local R = {}",
    "R.__index = R",
    "function R:m()",
    "   return setmetatable({}, gone_mt)",
    "end",
    "local gone_mt = { __index = R }",
    "local kept_mt = { __index = R, __gc = f }",
    "local a = setmetatable({ x = (\"a, b\"), y = f(1, 2), z = { 1, 2 } },",
    "   gone_mt)",
    "local b = setmetatable(a, gone_mt)",
    "local c = setmetatable({}, kept_mt)",
    "local d = setmetatable({ n = 1 }, { __index = R })",
    "local e = setmetatable({ n = 1 }, { __index = R, __mode = \"k\" })",
    "local f = not_setmetatable({}, gone_mt)",
    "local g = setmetatable(setmetatable({}, gone_mt), gone_mt)")
  local parsed = Parser.parse(Lexer.lex("local class R\n  n: integer\nend\n", "t.tl"), "t.tl", "tl")
  local got = Codegen.fork_without_classes(fork_lua, parsed.chunk, { "gone_mt" })
  assert(got == table.concat({
    "local kept_mt = { __index = R, __gc = f }",
    "local a = { x = (\"a, b\"), y = f(1, 2), z = { 1, 2 } }",
    "local b = a",
    "local c = setmetatable({}, kept_mt)",
    "local d = { n = 1 }",
    "local e = setmetatable({ n = 1 }, { __index = R, __mode = \"k\" })",
    "local f = not_setmetatable({}, gone_mt)",
    "local g = {}",
  }, "\n"), got)
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
  assert(generated("f(if y then false else 2 end)\n").text:find("function", 1, true))
end

-- if expressions written as if statements ---------------------------------------------------------------------------

--- Whether `text` has a function made and called on the spot.
local function has_closure(text: string): boolean
  return text:find("(function(", 1, true) ~= nil
end

local function test_an_if_expression_that_may_be_false_is_an_if_statement_in_a_local_an_assignment_and_a_return()
  local cases: {string: string} = {
    ["local x = if c then a else b end\nreturn x\n"] = "local x; if c then x = a else x = b end\nreturn x\n",
    ["x = if c then a else b end\n"] = "if c then x = a else x = b end\n",
    ["return if c then a else b end\n"] = "if c then return (a) else return (b) end\n",
    ["local x = if c then a elseif d then false else b end\n"] = "local x; if c then x = a elseif d then x = false else x = b end\n",
    ["local x = if c then (if d then a else b end) else f() end\n"] = "local x; if c then if d then x = a else x = b end else x = f() end\n",
    ["local x = if c then if d then a else 1 end else f() end\n"] = "local x; if c then if d then x = a else x = 1 end else x = f() end\n",
  }
  for source, expected in pairs(cases) do
    local text = generated(source).text
    -- The text has no newline after its last line.
    assert(text .. "\n" == expected, "for " .. source .. "the generator wrote\n" .. text .. "\nnot\n" .. expected)
  end
end

local function test_the_common_if_expressions_make_no_function()
  local sources: {string} = {
    "local x = if c then a else b end\n",
    "local x = if c then a elseif d then b else 3 end\n",
    "x = if c then a else nil end\n",
    "return if c then a else b end\n",
    "local x = if c then if d then a else b end else 3 end\n",
    "local x = if c then 1 else 2 end\n",
    "local function f(...: any): any\n  return if c then ... else 0 end\nend\n",
    "local function f(): any\n  return if c then g() else (h()) end\nend\n",
  }
  for _, source in ipairs(sources) do
    local text = generated(source).text
    assert(not has_closure(text), "a function in\n" .. text)
  end
end

local function test_an_if_expression_in_a_place_where_order_is_not_kept_stays_a_function()
  local sources: {string} = {
    "f(1, if c then a else b end)\n",
    "t.k = if c then a else b end\n",
    "return 1, if c then a else b end\n",
    "local x <const> = if c then a else b end\n",
    "local x <close> = if c then a else b end\n",
    "local x, y = if c then a else b end\n",
    "local x = if c then x else 1 end\n",
    "local x = 1 + (if c then a else b end)\n",
    "a, b = if c then a else b end, 2\n",
  }
  for _, source in ipairs(sources) do
    assert(has_closure(generated(source).text), "no function for " .. source)
  end
end

local function test_an_if_statement_takes_only_the_arm_that_holds_and_in_the_order_of_the_source()
  local source = program(
    "local log: {string} = {}",
    "local function see(name: string, value: any): any",
    "  log[#log + 1] = name",
    "  return value",
    "end",
    "local a = if see(\"c1\", false) then see(\"a\", 1) elseif see(\"c2\", true) then see(\"b\", false) else see(\"c\", 3) end",
    "local b",
    "b = if see(\"c3\", nil) then see(\"d\", 1) else see(\"e\", nil) end",
    "local function r(): any",
    "  return if see(\"c4\", true) then see(\"f\", false) else see(\"g\", 1) end",
    "end",
    "local c = r()",
    "return a, b, c, table.concat(log, \",\")")
  local a, b, c, order = run(source)
  assert(a == false and b == nil and c == false, tostring(a) .. " " .. tostring(b) .. " " .. tostring(c))
  assert(order == "c1,c2,b,c3,e,c4,f", order)
end

local function test_an_if_statement_gives_false_and_nil_as_they_are_and_one_value()
  local source = program(
    "local function two(): integer, integer return 1, 2 end",
    "local function count(...: any): integer return select(\"#\", ...) end",
    "local function one(c: boolean): any",
    "  return if c then two() else nil end",
    "end",
    "local function none(c: boolean): any",
    "  return if c then nil else false end",
    "end",
    "local function rest(...: any): any",
    "  local x = if select(\"#\", ...) > 1 then ... else false end",
    "  return x",
    "end",
    "local function rest_return(...: any): any",
    "  return if select(\"#\", ...) > 1 then ... else false end",
    "end",
    "return count(one(true)) * 10000 + count(none(true)) * 1000 + count(none(false)) * 100 + count(rest_return(5, 6)) * 10",
    "  + count(rest_return()), rest(5, 6), rest(5), none(false)")
  local counts, first, second, third = run(source)
  assert(counts == 11111 and first == 5 and second == false and third == false, tostring(counts))
end

local function test_a_local_made_from_an_if_statement_is_not_the_one_its_arms_read()
  local source = program(
    "local x = 10",
    "do",
    "  local x = if x > 5 then x else false end",
    "  local y = if x then x else false end",
    "  x = if not y then 1 else nil end",
    "  return x, y",
    "end")
  local x, y = run(source)
  assert(x == nil and y == 10)
  local text = generated("local x = 10\nlocal x = if x > 5 then x else false end\nreturn x\n").text
  assert(has_closure(text), text)
end

local function test_a_nested_if_expression_and_a_loop_with_continue_stay_correct()
  local source = program(
    "local function grade(n: integer): any",
    "  return if n > 90 then if n > 99 then false else \"a\" end elseif n > 50 then nil else (if n > 10 then \"c\" else false end) end",
    "end",
    "local out: {any} = {}",
    "for i = 1, 4 do",
    "  if i == 2 then continue end",
    "  local g = if i == 1 then false else i end",
    "  out[#out + 1] = g",
    "  if i == 4 then",
    "    return grade(100) == false and grade(95) == \"a\" and grade(60) == nil and grade(20) == \"c\" and grade(1) == false,",
    "      out[1] == false and out[2] == 3 and out[3] == 4 and #out == 3",
    "  end",
    "end")
  local graded, looped = run(source)
  assert(graded == true and looped == true)
end

local function test_an_if_statement_keeps_the_lines_of_the_source_for_an_error_in_an_arm()
  local source = program(
    "local function boom(): any",
    "  error(\"boom\")",
    "end",
    "local function run(): any",
    "  local x = if false then boom",
    "    elseif false then boom",
    "    else boom()",
    "  end",
    "  return x",
    "end",
    "return pcall(run)")
  local text = generated(source).text
  assert(not has_closure(text), text)
  local ok, message = run(source)
  assert(ok == false and tostring(message):find("^t:2: boom") ~= nil, tostring(message))
  local _, lines = text:gsub("\n", "\n")
  local _, source_lines = source:gsub("\n", "\n")
  assert(lines + 1 == source_lines, "the Lua has " .. tostring(lines) .. " lines to the source's " .. tostring(source_lines))
  -- The keywords stay on the lines the source has them on.
  local at = 0
  local found = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    at = at + 1
    if line:find("^%s*else x = boom") ~= nil or line:find("^%s*else") ~= nil and line:find("x = boom()", 1, true) ~= nil then
      found = at
    end
  end
  assert(found == 7, "the else is at line " .. tostring(found) .. "\n" .. text)
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

--- The generator reads one file, so a name of another module is a table unless the checker says what it stands for.
local function test_a_name_of_another_module_is_tested_for_what_the_checker_resolved_it_to()
  local text = program(
    "local D = require(\"d\")",
    "local function f(v: any): boolean",
    "  return v is D.Name",
    "end",
    "local function g(v: any): boolean",
    "  return v is D.Count",
    "end",
    "local function h(v: any): boolean",
    "  return v is D.Flag",
    "end",
    "return f, g, h")
  local parsed = Parser.parse(Lexer.lex(text, "t.tl"), "t.tl", "tl")
  local scoped = Scopes.build(parsed.chunk, "t.tl", {})
  local words: {string: string} = { Name = "string", Count = "integer", Flag = "true" }
  local kinds: mut {integer: string} = {}
  -- Every node, the walk's own list growing as it goes.
  local nodes: {Ast.Node} = { parsed.chunk.body }
  for _, node in ipairs(nodes) do
    if (node.kind == "TypeName") then
      local member = node.path[2]
      if member ~= nil then
        local word = words[member]
        if word ~= nil then
          kinds[node.id] = word
        end
      end
    end
    Ast.children(node, function(child: Ast.Node)
      nodes[#nodes + 1] = child
    end)
  end
  local without = Codegen.generate(parsed.chunk, scoped)
  assert(select(2, without.text:gsub('type%(v%) == "table"', "")) == 3, without.text)
  local with = Codegen.generate(parsed.chunk, scoped, nil, nil, nil, nil, kinds)
  assert(with.text:find('type(v) == "string"', 1, true) and with.text:find('math.type(v) == "integer"', 1, true), with.text)
  assert(with.text:find("return v == true", 1, true), with.text)
end

-- Checks of the parameters ----------------------------------------------------------------------------------------------

--- The Lua of `source` (a module `t.tl` the checker takes) with the parameter checks of [`lang.boundary_checks`], and without.
local function with_and_without_checks(source: string): string, string
  local checked = Programs.run(source)
  assert(Programs.codes(checked) == "", Programs.codes(checked))
  local checks = BoundaryChecks.of(checked.result.boundaries, source, "t.tl")
  local with = Codegen.generate(checked.chunk, checked.scoped, nil, nil, nil, nil, nil, nil, checks)
  assert(#with.errors == 0)
  return with.text, Programs.lua(checked)
end

--- Lines of `text` with the checks taken out, as the unchecked Lua is.
local function without_checks(text: string): string
  return (text:gsub(" if __cosmic_tc and [^\n]- end", ""))
end

local function test_a_check_is_a_statement_on_the_line_of_the_header_and_no_line_moves()
  local source = table.concat({
    "local function f(a: integer, b: string?): string",
    "  return b or \"x\"",
    "end",
    "",
  }, "\n")
  local with, without = with_and_without_checks(source)
  local first = assert(with:match("^[^\n]*"))
  assert(first == 'local function f(a, b) if __cosmic_tc and (__cosmic_mt(a) ~= "integer" or (b ~= nil and __cosmic_ty(b) ~= "string")) then __cosmic_tc(2, "p;t.tl:1;f;a=integer;b=string|nil", a, b) end',
    first)
  assert(without_checks(with) == without, with)
  local _, lines = with:gsub("\n", "")
  local _, plain = without:gsub("\n", "")
  assert(lines == plain)
end

-- Ahead of a module run with a hook of the test's own: an environment holding only the `type` and `math.type` that the
-- worker defines as `__cosmic_ty` and `__cosmic_mt`, which the chunk is given as its arguments.
local ENV_OF_THE_HOOK <const> = "local ty, mt = ... local _ENV = { __cosmic_ty = ty, __cosmic_mt = mt } "

--- The fast path: each parameter is tested by its Lua kind where it is, the hook is called only on a mismatch (and with the
--- spec as a literal, not built), and the tests read `type` and `math.type` by names no program can shadow.
local function test_the_check_tests_the_kinds_inline_and_calls_the_hook_only_on_a_mismatch()
  local source = table.concat({
    "local function f(type: string, math: {string}, n: integer | string, u: number?, w: boolean | {string: integer}): integer",
    "  return 1",
    "end",
    "local _ = f",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  local first = assert(with:match("^[^\n]*"))
  local expected = 'local function f(type, math, n, u, w) if __cosmic_tc and (__cosmic_ty(type) ~= "string" or ' ..
    '__cosmic_ty(math) ~= "table" or (__cosmic_mt(n) ~= "integer" and __cosmic_ty(n) ~= "string") or ' ..
    '(u ~= nil and __cosmic_ty(u) ~= "number") or (__cosmic_ty(w) ~= "boolean" and __cosmic_ty(w) ~= "table")) then ' ..
    '__cosmic_tc(2, "p;t.tl:1;f;type=string;math=table;n=integer|string;u=number|nil;w=boolean|table", type, math, n, u, w) end'
  assert(first == expected, first)
  local hook = "local calls = 0 __cosmic_tc = function() calls = calls + 1 end " ..
    "local result = (function() "
  local function calls(call: string): integer
    local chunk = assert(load(ENV_OF_THE_HOOK .. hook .. with .. "\n" .. call .. " end)() return calls", "=t", "t", {}))
    local count = chunk(type, math.type)
    assert(count is integer)
    return count
  end
  assert(calls("f('s', {}, 3, 1.5, true) f('s', {}, 'x', nil, {})") == 0)
  assert(calls("f(1, {}, 3, 1.5, true)") == 1)
  assert(calls("f('s', {}, 3.5, 1.5, true)") == 1)
  assert(calls("f('s', {}, 3, 'n', true)") == 1)
  assert(calls("f('s', {}, 3, nil, 1)") == 1)
  assert(calls("f('s', nil, 3, nil, true)") == 1)
end

local function test_a_return_that_is_a_tail_call_stays_one()
  local source = table.concat({
    "local function g(n: integer): integer",
    "  return n",
    "end",
    "local function f(n: integer): integer",
    "  return g(n)",
    "end",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  -- Nothing wraps the `return`, so the call is the last thing the function does.
  assert(with:find("return g(n)\nend", 1, true) ~= nil, with)
end

local function test_a_variadic_parameter_self_and_an_any_parameter_get_no_check()
  local source = table.concat({
    "local record R",
    "  n: integer",
    "end",
    "local function loose(a: any, ...: integer): integer",
    "  return 1",
    "end",
    "function R.bump(self: R, by: integer): integer",
    "  return self.n + by",
    "end",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  assert(with:find("local function loose(a, ...)\n", 1, true) ~= nil, with)
  assert(with:find('function R.bump(self, by) if __cosmic_tc and __cosmic_mt(by) ~= "integer" then __cosmic_tc(2, "p;t.tl:7;R.bump;by=integer", by) end',
    1, true) ~= nil, with)
end

local function test_a_method_of_a_class_checks_its_parameters_but_not_self()
  local source = table.concat({
    "local class Counter",
    "  mut total: integer",
    "  function add(self: Counter, by: integer, label: string?)",
    "    self.total = self.total + by",
    "  end",
    "end",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  assert(with:find('Counter.add(self, by, label) if __cosmic_tc and (__cosmic_mt(by) ~= "integer" or (label ~= nil and __cosmic_ty(label) ~= "string")) then __cosmic_tc(2, "p;t.tl:3;Counter.add;by=integer;label=string|nil", by, label) end',
    1, true) ~= nil, with)
end

local function test_a_header_over_several_lines_is_checked_on_its_last_line()
  local source = table.concat({
    "local function f(",
    "  a: integer,",
    "  b: boolean",
    "): integer",
    "  return a",
    "end",
    "",
  }, "\n")
  local with, without = with_and_without_checks(source)
  assert(with:find('b) if __cosmic_tc and (__cosmic_mt(a) ~= "integer" or __cosmic_ty(b) ~= "boolean") then __cosmic_tc(2, "p;t.tl:1;f;a=integer;b=boolean", a, b) end\n', 1, true) ~= nil, with)
  assert(without_checks(with) == without, with)
end

local function test_a_function_literal_and_its_parameters_are_checked_in_place()
  local source = table.concat({
    "local inc = function(n: integer): integer return n + 1 end",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  assert(with:find('local inc = function(n) if __cosmic_tc and __cosmic_mt(n) ~= "integer" then __cosmic_tc(2, "p;t.tl:1;function;n=integer", n) end return n + 1 end',
    1, true) ~= nil, with)
end

--- The check calls the hook with the values and the function runs on; where no hook is defined it does nothing.
local function test_the_check_calls_the_hook_with_the_values_and_the_function_runs_on()
  local source = table.concat({
    "local function f(a: integer, b: string): integer",
    "  return a",
    "end",
    "local _ = f",
    "",
  }, "\n")
  local with = with_and_without_checks(source)
  -- The hook is defined by the chunk that runs the module, in an environment of its own that holds nothing else.
  local hook = "local log = {} __cosmic_tc = function(n, spec, a, b) log[#log + 1] = n .. ' ' .. spec .. ' ' .. a .. ' ' .. b " ..
    "return a end local result = (function() "
  -- Values that fit never reach the hook: the test written ahead of its call passes them by.
  local fits = assert(load(ENV_OF_THE_HOOK .. hook .. with .. "\nreturn f(7, 's') end)() return result, #log", "=t", "t", {}))
  local fitted, calls = fits(type, math.type)
  assert(fitted == 7 and calls == 0, tostring(calls))
  local chunk = assert(load(ENV_OF_THE_HOOK .. hook .. with .. "\nreturn f(7, 5) end)() return result, log[1], #log", "=t", "t", {}))
  local result, seen, count = chunk(type, math.type)
  assert(result == 7 and count == 1, tostring(count))
  assert(seen == "2 p;t.tl:1;f;a=integer;b=string 7 5", tostring(seen))
  assert(assert(load(with .. "\nreturn f(7, 's')", "=t", "t", {}))() == 7)
end
