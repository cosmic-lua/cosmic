--- Tests of [`build.error_render`]: the errors and warnings of the new checker's driver as the lines a build prints, one
--- real program for each stage that reports (the lexer, the parser, the scope builder, the lowering of
--- declarations, the checker's expressions, its flow, its generics, and the warnings).
local Driver = require("build.driver")
local ErrorRender = require("build.error_render")
local Programs = require("lang.check_programs")
local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local schema = require("build.schema")

Test.policy{}

local function nothing(_file: string): boolean
  return false
end

--- The result for the module `m` of the text `text`.
local function result_of(text: string, stubs?: {string: string}): Driver.Outcome
  local index = Driver.index({ { "m.tl", text } }, nothing)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library .. "\n", {}) },
    adjust = nil, external = {}, types = false,
  })
  build:provide(Driver.files(index))
  build:provide(Driver.stubs(stubs or {}))
  return assert(build:result("m", true))
end

--- The element `i` of `list`, which a test expects to be there.
local function at(list: {string}, i: integer): string
  local found: string? = nil
  for index, line in ipairs(list) do
    if index == i then
      found = line
    end
  end
  assert(found ~= nil, "no line " .. tostring(i))
  return found
end

local function render(text: string): {string}
  return ErrorRender.lines(result_of(text))
end

--- The one line `text` renders to.
local function only(text: string): string
  local lines = render(text)
  assert(#lines == 1, tostring(#lines) .. " lines for " .. text .. ": " .. table.concat(lines, " | "))
  return at(lines, 1)
end

local function test_a_lexical_error_is_a_line_with_its_place_message_code_and_fix()
  assert(only("local x = 1_000\nprint(x)\n") ==
      "m.tl:1:11: `_` in a number is not in the grammar (digit_separator): write the number without `_`: `1000`")
end

local function test_a_syntax_error_is_a_line_with_its_place_message_code_and_fix()
  assert(only("local x = = 1\n") ==
      "m.tl:1:11: expected an expression, found `=` (expected_expression): write a value: a name, a number, a string, " ..
      "`nil`, `true`, `false`, a table `{ ... }`, a call, or `function(...) ... end`")
  assert(only("local function f()\n  print(1)\n") ==
      "m.tl:3:1: expected `end` to close the function `f` on line 1, found the end of the file (unclosed): write `end` " ..
      "where the function `f` on line 1 ends, or delete its `function`")
end

local function test_an_error_of_the_scope_builder_is_a_line_with_its_place_message_code_and_fix()
  assert(only("print(nothing_here)\n") ==
      "m.tl:1:7: `nothing_here` is not declared (unknown_variable): declare it with `local nothing_here = ...` above this " ..
      "use, or require its module with `local nothing_here = require(\"...\")`; a program has no globals except the ones " ..
      "a declaration file declares")
  assert(only("local x = 1\nlocal function f(): integer\n  local x = 2\n  return x\nend\nprint(f(), x)\n") ==
      "m.tl:3:9: variable `x` shadows the variable `x` declared at 1:7 (shadows): rename the new `x` (the old one is " ..
      "declared at 1:7 and stays visible if this one has another name)")
end

local function test_a_form_the_grammar_drops_is_a_line_of_the_parser()
  assert(only("local x: {integer, string} = nil\nprint(x)\n") ==
      "m.tl:1:18: a tuple type `{A, B}` is not in the grammar (tuple_type): write a record with a field for each " ..
      "position, or `{A | B}` for an array of either")
end

local function test_an_error_of_the_lowering_of_declarations_is_a_line_with_its_place_message_code_and_fix()
  local lines = render("local record R\n  x: integer\n  x: string\nend\nreturn R\n")
  assert(#lines == 2)
  assert(at(lines, 1) == "m.tl:3:3: the field `x` is declared twice (duplicate_field): delete one; overloads, which repeat a " ..
      "function-typed field, are declared in a declaration file", at(lines, 1))
  assert(at(lines, 2) == "m.tl:3:3: `x` is declared twice in `R` (repeated_field): rename or remove one of them: the fields " ..
      "and methods of a record or class share one namespace", at(lines, 2))
  assert(only("local type Bad = {number: string}\nlocal x: Bad = nil\nprint(x)\n"):find("(float_key): ", 1, true) ~= nil)
end

local function test_an_error_of_the_checkers_expressions_is_a_line_with_its_place_message_code_and_fix()
  assert(only("local n: integer = \"s\"\nprint(n)\n") ==
      "m.tl:1:20: `\"s\"` is `string`, where `integer` is wanted as the value of `n` (not_assignable): pass a value of " ..
      "type `integer`, or change the declaration to `string`")
end

local function test_an_error_of_the_checkers_flow_is_a_line_with_its_place_message_code_and_fix()
  assert(only("local function f(): integer\nend\nreturn f\n") ==
      "m.tl:1:1: control can reach the end of this function, which answers (integer), with no `return` (missing_return): " ..
      "end every path with a `return` of (integer) (or `error(...)`), or declare the function without a return list")
  assert(only("local x: integer\nprint(x)\n") ==
      "m.tl:2:7: `x` is read before every path assigns it: `local x` was given no value (not_assigned): assign `x` on " ..
      "every path before this read, give it a value where it is declared (`local x: integer = ...`), or declare it " ..
      "`integer?`, which is nil until assigned and is checked where it is used")
end

local function test_an_error_of_the_checkers_generics_is_a_line_with_its_place_message_code_and_fix()
  assert(only("local function empty<T>(): {T}\n  return {}\nend\nlocal xs = empty()\nprint(xs)\n") ==
      "m.tl:4:12: `empty` is generic, and nothing fixes its type parameter `T`: no argument has it, and the call is not " ..
      "expected to answer it (cannot_infer): type the result, so the call is expected to have the type " ..
      "(`local v: T = empty(...)`), or pass an argument that has it")
end

local function test_a_warning_is_a_line_like_an_error_and_follows_the_errors_of_its_module()
  local lines = render("local function a()\nend\nlocal n: integer = \"s\"\nprint(n)\nlocal u = 1\n")
  assert(#lines == 3, table.concat(lines, "\n"))
  assert(at(lines, 1):find("^m%.tl:3:20: ") ~= nil and at(lines, 1):find("(not_assignable): ", 1, true) ~= nil, at(lines, 1))
  assert(at(lines, 2) == "m.tl:1:16: unused function a (unused_function): remove it, or return it from the module if other " ..
      "files call it", at(lines, 2))
  assert(at(lines, 3) == "m.tl:5:7: unused variable u (unused_variable): name it `_` or `_u` to say it is meant to be " ..
      "unused, or remove it", at(lines, 3))
end

local function test_a_fix_repeated_in_a_file_is_printed_once_with_how_many_more_lines_it_holds_for()
  local lines = render("local n: integer = \"s\"\nlocal m: integer = \"t\"\nprint(n, m)\nlocal function a()\nend\n" ..
      "local function b()\nend\nlocal function c()\nend\n")
  assert(#lines == 5, table.concat(lines, "\n"))
  assert(at(lines, 1) == "m.tl:1:20: `\"s\"` is `string`, where `integer` is wanted as the value of `n` (not_assignable): " ..
      "pass a value of type `integer`, or change the declaration to `string` (same for 1 more)", at(lines, 1))
  assert(at(lines, 2) == "m.tl:2:20: `\"t\"` is `string`, where `integer` is wanted as the value of `m` (not_assignable)", at(lines, 2))
  assert(at(lines, 3):find("unused function a (unused_function): remove it, or return it from the module if other files call it (same for 2 more)", 1, true) ~= nil, at(lines, 3))
  assert(at(lines, 4) == "m.tl:6:16: unused function b (unused_function)", at(lines, 4))
  assert(at(lines, 5) == "m.tl:8:16: unused function c (unused_function)", at(lines, 5))
end

local function test_a_module_with_no_problem_renders_nothing()
  local result = result_of("local n: integer = 1\nprint(n)\n")
  assert(#ErrorRender.lines(result) == 0 and ErrorRender.complain(result) == "")
  assert(ErrorRender.complain(result_of("local x = = 1\n")):find("\n", 1, true) == nil)
  local two = ErrorRender.complain(result_of("local n: integer = \"s\"\nlocal m: integer = 2.5\nprint(n, m)\n"))
  assert(select(2, two:gsub("\n", "")) == 1, two)
end

local function test_a_name_cosmic_removed_is_a_line_whose_fix_is_what_to_write_instead()
  assert(only("print(os.getenv(\"HOME\"))\n") ==
      "m.tl:1:7: `os` is not declared (unknown_variable): " .. Removed.message("os", "getenv"))
  assert(only("local m = require(\"io\")\nprint(m)\n") ==
      "m.tl:1:11: the project has no module `io` (require_unknown): " .. Removed.message("io"))
end

--- A shipped database with a documented [`Fs.read`] and the worked examples the diagnostics point to.
local function hinted(): ErrorRender.Hints, Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  assert(Sqlite.run(db,
    "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
      "VALUES ('cosmic.fs', 'cosmic/fs.tl', 'module', '', '', '', '', '')"))
  assert(Sqlite.run(db,
    "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, text, file, line) " ..
      "VALUES ('cosmic.fs', 'Fs.read', 'Fs.read', 1, 'function', 'function Fs.read(path: string): string', " ..
      "'Reads a file.', 'cosmic/fs.tl', 3)"))
  for _, name in ipairs({ "records_interfaces_methods", "generics_functions_returns" }) do
    assert(Sqlite.run(db,
      "INSERT INTO examples (module, name, text, file, line, source) " ..
        "VALUES ('cosmic.fs', ?1, 'Records.', 'cosmic/fs.tl', 9, 'local x = 1')", { { text = name } }))
  end
  assert(db:exec("INSERT INTO docs_fts(docs_fts) VALUES ('rebuild')"))
  assert(db:exec("INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')"))
  return function(): {Sqlite.Handle}, {boolean}
    return { db }, { false }
  end, db
end

local function test_a_name_the_checker_could_not_resolve_points_at_what_cosmic_docs_answers_for_it()
  local hints, db = hinted()
  local lines = ErrorRender.lines(result_of("print(read)\n"), hints)
  assert(#lines == 1 and at(lines, 1):sub(-#" -- see also in docs: Fs.read") == " -- see also in docs: Fs.read", at(lines, 1))
  local module = ErrorRender.lines(result_of("local m = require(\"read\")\nprint(m)\n"), hints)
  assert(at(module, 1):sub(-#" -- see also in docs: Fs.read") == " -- see also in docs: Fs.read", at(module, 1))
  -- a name the docs do not know is told nothing more, and so is a module that is found
  local unknown = ErrorRender.lines(result_of("print(nothing_here)\n"), hints)
  assert(at(unknown, 1):find("see also", 1, true) == nil, at(unknown, 1))
  db:close()
end

local function test_a_call_or_a_field_the_checker_refused_points_at_the_example_that_teaches_the_form()
  local hints, db = hinted()
  local arity = ErrorRender.lines(result_of("local function f(a: integer): integer\n  return a\nend\nprint(f(1, 2))\n"), hints)
  assert(#arity == 1 and at(arity, 1):find("(arity): ", 1, true) ~= nil, at(arity, 1))
  assert(at(arity, 1):sub(-#" -- see also: cosmic docs generics_functions_returns") == " -- see also: cosmic docs generics_functions_returns", at(arity, 1))
  local field = ErrorRender.lines(result_of("local o: Opts = { n = 1 }\nprint(o.zzz)\n"), hints)
  assert(#field == 1 and at(field, 1):sub(-#" -- see also: cosmic docs records_interfaces_methods") ==
      " -- see also: cosmic docs records_interfaces_methods", at(field, 1))
  -- the replacement of a removed member is the answer, and no example is pointed to beside it
  local removed = ErrorRender.lines(result_of("local Hash = require(\"cosmic.hash\")\nlocal d = Hash.hex(\"x\")\nprint(d)\n",
    { ["cosmic.hash"] = "local record Hash\n  alive: integer\nend\nreturn Hash\n" }), hints)
  assert(#removed == 1 and at(removed, 1):find("Hash.hex was removed: ", 1, true) ~= nil, at(removed, 1))
  assert(at(removed, 1):find("see also", 1, true) == nil, at(removed, 1))
  -- an example the databases lack is not advertised
  local bare = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(bare:exec(statement))
  end
  local none = ErrorRender.lines(result_of("local o: Opts = { n = 1 }\nprint(o.zzz)\n"), function(): {Sqlite.Handle}, {boolean}
    return { bare }, { false }
  end)
  assert(at(none, 1):find("see also", 1, true) == nil, at(none, 1))
  bare:close()
  db:close()
end

local function test_a_line_is_its_place_message_code_and_fix()
  local result = result_of("local n: integer = \"s\"\nprint(n)\n")
  local p: Driver.Problem? = nil
  for _, e in ipairs(result.errors) do
    p = e
  end
  assert(p ~= nil)
  assert(ErrorRender.line("a/b.tl", p) == "a/b.tl:1:20: " .. p.msg .. " (not_assignable): " .. p.fix)
end

local function test_the_examples_a_diagnostic_points_to_are_the_ones_the_build_has_always_pointed_to()
  assert(ErrorRender.queries.arguments == "generics_functions_returns")
  assert(ErrorRender.queries.record_key == "records_interfaces_methods")
end

--- The line a build prints for the first error of `text`, with the examples `hinted` holds.
local function first_line(text: string, stubs?: {string: string}): string
  local hints, db = hinted()
  local lines = ErrorRender.lines(result_of(text, stubs), hints)
  db:close()
  return at(lines, 1)
end

local POINTER <const> = " -- see also: cosmic docs generics_functions_returns"

local function test_a_value_refused_by_a_parameter_points_at_the_example_whoever_declares_the_function()
  -- a project's own function
  local own = first_line("local function f(a: integer): integer\n  return a\nend\nprint(f(\"s\"))\n")
  assert(own:find("(not_assignable): ", 1, true) ~= nil and own:sub(-#POINTER) == POINTER, own)
  -- a function of the standard library
  local library = first_line("local n = string.packsize(1)\nprint(n)\n")
  assert(library:find("(not_assignable): ", 1, true) ~= nil and library:sub(-#POINTER) == POINTER, library)
  -- a function of another module of the project
  local other = first_line("local W = require(\"w\")\nprint(W.f(\"s\"))\n",
    { w = "local record W\n  f: function(a: integer): integer\nend\nreturn W\n" })
  assert(other:find("(not_assignable): ", 1, true) ~= nil and other:sub(-#POINTER) == POINTER, other)
end

local function test_a_plain_assignment_that_is_refused_points_at_no_example()
  local line = first_line("local n: integer = \"s\"\nprint(n)\n")
  assert(line:find("(not_assignable): ", 1, true) ~= nil and line:find("see also", 1, true) == nil, line)
end

local function test_the_fix_of_a_removed_name_beats_the_pointer_of_an_argument()
  local result = result_of("local Hash = require(\"cosmic.hash\")\nlocal d = Hash.hex(\"x\")\nprint(d)\n",
    { ["cosmic.hash"] = "local record Hash\n  alive: integer\nend\nreturn Hash\n" })
  local problem = result.errors[1]
  assert(problem ~= nil)
  -- the same problem, made an argument's: the replacement is still the answer
  local function marked(removed: boolean): Driver.Problem
    return {
      kind = problem.kind, stage = problem.stage, code = "not_assignable", msg = problem.msg, fix = problem.fix, y = problem.y,
      x = problem.x, offset = problem.offset, removed = removed,
      argument = { callee = "Hash.hex", module = "cosmic.hash", position = 1 },
    }
  end
  local hints, db = hinted()
  assert(ErrorRender.pointers(result, marked(true), hints) == "")
  assert(ErrorRender.pointers(result, marked(false), hints) == POINTER)
  db:close()
end
