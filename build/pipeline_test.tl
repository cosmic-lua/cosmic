--- The tests of [`build.pipeline`]: a module of the fork's Teal read, checked against its ceilings and written as Lua and bytecode by the
--- new checker, the way [`build.compilation`]'s `generate` answers for the fork's compiler. The Lua is run, and compared
--- with what the generator writes alone ([`lang.codegen`]) and with the fork's, over the files of the tree.
local Ceilings = require("build.ceilings")
local Codegen = require("lang.codegen")
local CompileGrammar = require("build.compile_grammar")
local Driver = require("build.driver")
local Fixture = require("build.syntax_typed_fixture")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Pipeline = require("build.pipeline")
local Programs = require("lang.check_programs")
local Scopes = require("lang.scopes")
local Stub = require("build.stub")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local compilation = require("build.compilation")
local compile = require("build.compile")
local importer = require("build.importer")
local schema = require("build.schema")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = {
  { path = "core", letters = "r" }, { path = "lang/ast.tl", letters = "r" }, { path = "lang/types.tl", letters = "r" },
  { path = "cosmic/removed_example.tl", letters = "r" }, { path = "checker/stdlib.d.tl", letters = "r" },
  { path = "checker/tl.tl", letters = "r" }, { path = "build/ceilings.txt", letters = "r" },
  { path = "build/importer.tl", letters = "r" }, { path = "build/plural.tl", letters = "r" },
  { path = "build/bind.tl", letters = "r" }, { path = "build/digest.tl", letters = "r" },
  { path = "build/clock.tl", letters = "r" }, { path = "build/assertions.tl", letters = "r" },
  { path = "build/exit_status.tl", letters = "r" }, { path = "build/key_parts.tl", letters = "r" },
  { path = "build/positions.tl", letters = "r" },
} }

local built = assert(teal.load())

--- The standard library of the checker's own tests, as the globals of every module, and the `cosmic.*` modules the cases name.
local STANDARD <const>: {string: string} = {
  ["cosmic.shape"] = table.concat({
    "local record Shape",
    "  record_of: function(string, ...: any): any",
    "  record: function(any): any",
    "  integer: any",
    "end",
    "return Shape",
    "",
  }, "\n"),
}

local function ceilings(text: string): Ceilings.Table
  return (assert(Ceilings.parse(text)))
end

local function options(pins: string): Pipeline.Options
  return {
    globals = {
      sources = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) },
      adjust = function(_globals: {string: Scopes.Global}) end,
    },
    ceilings = ceilings(pins), types = true, standard = Driver.stubs(STANDARD), project = nil,
  }
end

--- The ceiling of a module that returns a value no declaration describes, which the new checker refuses and the programs
--- below, written to be run as Lua as well, do.
local EXPORT <const> = "[checked]\nm.tl export_not_declared 1\n"

--- The plan of the module `path` that is the file `file` of kind `kind`, as the stage plans one.
local function module_of(path: string, file: string, kind: string, source: string, tests: {string}): compilation.Module
  return {
    path = path, file = file, kind = kind, source = source, source_hash = "", requires = {}, tests = tests,
    has_top_level_return = true, generated = false, key = "", graph_key = "", lua = "",
  }
end

--- What the pipeline answers for one module `source` of the file `m.tl`, under the ceilings `pins`.
local function generated(source: string, pins?: string, kind?: string, tests?: {string}): compilation.Generated | nil, string
  local pipeline = Pipeline.over({ { "m.tl", source } }, { ["m.tl"] = kind or "module" }, options(pins or ""))
  return Pipeline.generate(module_of("m", "m.tl", kind or "module", source, tests or {}), pipeline)
end

--- The value the Lua of a module returns.
local function value_of(lua: string): any
  return assert(load(lua, "=m", "t"))()
end

local function test_a_module_is_checked_written_and_dumped_and_the_lua_and_the_bytecode_run()
  local source = "local record Box\n  n: integer\nend\nlocal function make(n: integer): Box\n  return { n = n }\nend\nreturn make(41).n + 1\n"
  local made = assert(generated(source, EXPORT))
  assert(value_of(made.lua) == 42 and not made.refused and #made.references == 0)
  assert(assert(load(made.bytecode, "=m", "b"))() == 42)
  assert(made.bytecode:sub(1, 4) == "\27Lua")
end

local function test_a_method_that_reads_a_function_written_after_its_record_runs_through_the_hoist()
  local source = table.concat({
    "local record R",
    "  n: integer",
    "end",
    "local function bump(r: R): integer",
    "  return r.n + 1",
    "end",
    "function R:next(): integer",
    "  return bump(self)",
    "end",
    "local r: R = { n = 41 }",
    "return R.next(r)",
    "",
  }, "\n")
  local made, why = generated(source, EXPORT)
  assert(made ~= nil, tostring(why))
  assert(value_of(made.lua) == 42, made.lua)
  local bump_at = assert(made.lua:find("local function bump", 1, true), made.lua)
  local next_at = made.lua:find("function R.next", 1, true) or made.lua:find("R.next = ", 1, true)
  assert(next_at ~= nil and bump_at < next_at, made.lua)
end

local function test_a_literal_a_hoisted_function_reads_moves_with_it_and_a_value_made_by_a_call_is_refused()
  local head = "local record R\n  n: integer\nend\n"
  local moved = generated(head .. "local base = 40\nlocal function plus(r: R): integer\n  return r.n + base\nend\n" ..
      "function R:go(): integer\n  return plus(self)\nend\nlocal r: R = { n = 2 }\nreturn R.go(r)\n", EXPORT)
  assert(moved ~= nil and value_of(moved.lua) == 42)
  -- the same program with `base` made by a call cannot move: the method would read a name declared below it
  local made, why = generated("local function forty(): integer\n  return 40\nend\n" .. head ..
      "local base = forty()\nfunction R:go(): integer\n  return self.n + base\nend\nlocal r: R = { n = 2 }\nreturn R.go(r)\n", EXPORT)
  assert(made == nil and why:find("(unknown_variable)", 1, true) ~= nil, tostring(why))
  -- a function that reads a call-made value stays where it is, so a method that calls it is refused as well
  local indirect, indirect_why = generated("local function forty(): integer\n  return 40\nend\n" .. head ..
      "local base = forty()\nlocal function plus(r: R): integer\n  return r.n + base\nend\nfunction R:go(): integer\n" ..
      "  return plus(self)\nend\nlocal r: R = { n = 2 }\nreturn R.go(r)\n", EXPORT)
  assert(indirect == nil and indirect_why:find("(unknown_variable)", 1, true) ~= nil, tostring(indirect_why))
end

local function test_an_import_read_as_a_value_stays_a_require_and_one_never_read_is_not_loaded()
  local dep = "local record Dep\n  n: integer\nend\nlocal d: Dep = { n = 3 }\nreturn d\n"
  local function lua_of(source: string): string
    local pipeline = Pipeline.over({ { "dep.tl", dep }, { "m.tl", source } }, { ["dep.tl"] = "module", ["m.tl"] = "module" },
      options(EXPORT))
    local made, why = Pipeline.generate(module_of("m", "m.tl", "module", source, {}), pipeline)
    assert(made ~= nil, tostring(why))
    return made.lua
  end
  local kept = lua_of("local type Dep = require(\"dep\")\nreturn Dep.n\n")
  assert(kept:find('local Dep = require("dep")', 1, true) ~= nil, kept)
  local erased = lua_of("local type _dep = require(\"dep\")\nreturn 7\n")
  assert(erased:find("require", 1, true) == nil and value_of(erased) == 7, erased)
end

local function test_a_test_module_hands_its_tests_back_and_none_is_unused()
  local source = "local function test_a(): integer\n  return 1\nend\nlocal function test_b(): integer\n  return 2\nend\n"
  local made = assert(generated(source, "", "test", { "test_a", "test_b" }))
  assert(made.lua:find("\nreturn { test_a = test_a, test_b = test_b }\n", 1, true) ~= nil, made.lua)
  local tests = value_of(made.lua) as {string: function(): integer}
  assert(tests.test_a() == 1 and tests.test_b() == 2)
  -- the same module is not a test: its functions are unused
  local plain, why = generated(source)
  assert(plain == nil and why:find("unused_function", 1, true) ~= nil, tostring(why))
end

local function test_a_count_over_its_ceiling_is_refused_with_the_words_of_the_check_of_the_tree()
  local source = "local n: string = 1\nreturn n\n"
  local made, why = generated(source)
  assert(made == nil)
  assert(why:find("^m.tl: the compiler refused it\nm.tl:1:") ~= nil, why)
  assert(why:find("(not_assignable)", 1, true) ~= nil and
      why:find("m.tl: 1 error of not_assignable in its bodies, pinned 0; follow the fix above rather than raise the pin", 1, true) ~= nil, why)
  -- the pin lets the module in, and the Lua is written line for line all the same
  local pinned = assert(generated(source, "[checked]\nm.tl not_assignable 1\n"))
  assert(value_of(pinned.lua) == 1)
  assert(generated(source, "[checked]\nm.tl not_assignable 5\n") ~= nil)
  -- a pin for another code, or another file, holds nothing of it
  assert(generated(source, "[checked]\nm.tl nil_not_allowed 1\n") == nil)
  assert(generated(source, "[checked]\nn.tl not_assignable 1\n") == nil)
end

local function test_a_warning_refuses_a_module_with_the_checkers_words()
  local made, why = generated("local unused = 1\nreturn 2\n", EXPORT)
  assert(made == nil and why:find("^m.tl: the compiler refused it\nm.tl:1:7: ") ~= nil, tostring(why))
  assert(why:find("(unused_variable)", 1, true) ~= nil, why)
end

local function test_a_translation_that_does_not_parse_is_counted_by_its_pin_and_never_compiled()
  local source = "local t: {{string, integer}}\nreturn t\n"
  local made, why = generated(source)
  assert(made == nil and why:find("(tuple_type)", 1, true) ~= nil, tostring(why))
  -- pinned, it is counted, and there is still no syntax tree to write Lua from
  local pinned, still = generated(source, "[translated]\nm.tl tuple_type 1\n")
  assert(pinned == nil and still:find("^m.tl: the compiler refused it\nm.tl:1:") ~= nil and
      still:find("(tuple_type)", 1, true) ~= nil, tostring(still))
end

--- A program with no annotation, which is Lua as it stands, so that it can be run both ways.
local PROGRAMS <const>: {string} = {
  "local n = 3\nreturn n > 2 and \"big\" or \"small\"\n",
  "local n = 1\nreturn n > 2 and \"big\" or \"small\"\n",
  "local v = nil\nreturn true and v or \"dflt\"\n",
  "local f = false\nreturn f and 1 or 7\n",
  "local n = 0\nreturn n == 0 and n or 9\n",
  "local a = false\nlocal b = 5\nreturn a and 1 or b\n",
}

local function test_the_lua_the_pipeline_writes_answers_what_the_program_answers_as_lua()
  for _, program in ipairs(PROGRAMS) do
    local made, why = generated(program, "[checked]\nm.tl export_not_declared 1\nm.tl and_ternary 5\n")
    assert(made ~= nil, program .. tostring(why))
    local want = { assert(load(program, "=plain", "t"))() }
    local got = { value_of(made.lua) }
    assert(#got == #want and got[1] == want[1] and got[2] == want[2], program .. made.lua)
  end
end

local function test_an_if_expression_over_a_value_the_translator_knows_is_never_false_is_not_written_as_a_call()
  -- the middle is a cast to a string: no literal, so only what the translator knows of it keeps the `and` and `or`
  local made = assert(generated("local n = 3\nlocal y: any = \"v\"\nlocal s: string = n > 2 and (y as string) or \"z\"\nreturn s\n",
    "[checked]\nm.tl cast_refused 1\nm.tl any_use 1\n", "example"))
  assert(made.lua:find("function", 1, true) == nil, made.lua)
  assert(value_of(made.lua) == "v")
end

local function test_a_record_the_build_describes_is_resolved_in_the_text_the_checker_reads_and_the_module_is_read_again()
  local source = table.concat({
    "local Shape = require(\"cosmic.shape\")",
    "local record R",
    "  n: integer",
    "end",
    "local S = Shape.record_of(\"R\")",
    "return S",
    "",
  }, "\n")
  -- the witness the build splices answers nothing, so the splice adds no error to the module: what is left is its own
  local refused, why = generated(source)
  assert(refused == nil and why:find("(export_not_declared)", 1, true) ~= nil and
      why:find("nil_not_allowed", 1, true) == nil, tostring(why))
  local pipeline = Pipeline.over({ { "m.tl", source } }, { ["m.tl"] = "module" }, options("[checked]\nm.tl export_not_declared 1\n"))
  local made = assert(Pipeline.generate(module_of("m", "m.tl", "module", source, {}), pipeline))
  assert(made.lua:find("record_of(\"R\", ", 1, true) ~= nil, made.lua)
  local read = assert(pipeline.build:parsed("m"))
  assert(read.text:find("function(): R error(\"witness\") end", 1, true) ~= nil and read.lowered ~= nil)
  -- a module without such a call is read once, as it was
  local plain = Pipeline.over({ { "p.tl", "return 1\n" } }, { ["p.tl"] = "module" },
    options("[checked]\np.tl export_not_declared 1\n"))
  assert(Pipeline.generate(module_of("p", "p.tl", "module", "return 1\n", {}), plain) ~= nil)
  assert(assert(plain.build:parsed("p")).text == "return 1\n")
end

local function test_a_module_the_build_lacks_is_refused_by_name()
  local pipeline = Pipeline.over({ { "m.tl", "return 1\n" } }, {}, options(""))
  local made, why = Pipeline.generate(module_of("gone", "gone.tl", "module", "return 1\n", {}), pipeline)
  assert(made == nil and why == "gone.tl: the new checker's build has no module gone", tostring(why))
end

local function test_the_steps_of_the_proof_are_made_to_the_three_files_and_to_the_tests_of_their_records()
  local entries: {{string}} = {}
  for _, file in ipairs({ "lang/ast.tl", "lang/types.tl", "cosmic/removed_example.tl" }) do
    entries[#entries + 1] = { file, (assert(Fs.read(file))) }
  end
  entries[#entries + 1] = { "t.tl", "local Ast = require(\"lang.ast\")\nlocal function is_name(n: Ast.Node): boolean\n  return n is Ast.Name\nend\nreturn is_name\n" }
  entries[#entries + 1] = { "plain.tl", "local x = 1\nreturn x\n" }
  local pipeline = Pipeline.over(entries, {}, options(""))
  local ast, types = assert(pipeline.build:parsed("lang.ast")), assert(pipeline.build:parsed("lang.types"))
  -- their `where` clauses are blanked, and they read in the new grammar
  assert(not ast.broken and not types.broken, tostring(ast.syntax[1] and ast.syntax[1].msg))
  assert(not ast.text:find("\n  where ", 1, true) and not types.text:find("\n    where ", 1, true))
  -- the example keeps the forms no step makes (a method outside its class, a tuple type): it is counted, not compiled
  local example = assert(pipeline.build:parsed("cosmic.removed_example"))
  local codes: {string} = {}
  for _, p in ipairs(example.syntax) do
    codes[#codes + 1] = p.code
  end
  assert(example.broken and table.concat(codes, " ") == "method_in_record tuple_type", table.concat(codes, " "))
  -- a test of a record they told apart is the test of the tag the clause was, wherever the test is written
  local tagged = assert(pipeline.build:parsed("t"))
  assert(tagged.text:find("n.kind == \"Name\"", 1, true) ~= nil, tagged.text)
  -- and a module that names neither is read as it is
  assert(assert(pipeline.build:parsed("plain")).text == "local x = 1\nreturn x\n")
end

local function test_without_the_two_modules_of_the_clauses_nothing_is_rewritten()
  local text = "local Ast = require(\"lang.ast\")\nlocal function is_name(n: Ast.Node): boolean\n  return n is Ast.Name\nend\nreturn is_name\n"
  local pipeline = Pipeline.over({ { "t.tl", text } }, {}, options(""))
  assert(assert(pipeline.build:parsed("t")).text == Translate.translate(text, "t.tl").text)
end

--- Files of the tree with no class and no test of an enum, whose Lua the generator writes as the fork's.
local CORPUS <const>: {string} = {
  "build/plural.tl", "build/bind.tl", "build/digest.tl", "build/clock.tl", "build/assertions.tl", "build/exit_status.tl",
  "build/key_parts.tl", "build/positions.tl",
}

--- The Lua the generator writes of `source` alone, as the check of the tree has it: no module served, no globals, and
--- the translator's word on what an `if` expression holds.
local function alone(file: string, source: string): string
  local made = Translate.translate(source, file)
  local parsed = Parser.parse(Lexer.lex(made.text, file), file, "tl")
  assert(#parsed.errors == 0, file)
  return Codegen.generate(parsed.chunk, Scopes.build(parsed.chunk, file, {}), Translate.never_false).text
end

local function test_the_lua_over_the_files_of_the_tree_is_the_generators_and_the_forks()
  local compared = 0
  local lines = 0
  for _, file in ipairs(CORPUS) do
    local source = assert(Fs.read(file))
    local pipeline = Pipeline.over({ { file, source } }, {}, options(""))
    local module = file:gsub("%.tl$", ""):gsub("/", ".")
    pipeline.build:lower({ module })
    local result = assert(pipeline.build:result(module, true))
    local emitted = CompileGrammar.emit(pipeline.build, result)
    local ours = assert(emitted.code, file .. ": " .. emitted.trouble)
    local oracle = alone(file, source)
    local fork = assert(compile.lua(built, file, source))
    assert(Codegen.compared(ours) == Codegen.compared(oracle), file .. " differs from the generator alone")
    assert(Codegen.compared(ours) == Codegen.compared(fork), file .. " differs from the fork's")
    compared = compared + 1
    for _ in ours:gmatch("\n") do
      lines = lines + 1
    end
  end
  assert(compared == #CORPUS and lines > 100, tostring(compared) .. " files, " .. tostring(lines) .. " lines")
  -- a difference planted in the Lua is told apart, in the line, in the order and in the count of lines
  local base = alone("build/bind.tl", (assert(Fs.read("build/bind.tl"))))
  local planted: {string} = {
    (base:gsub("return", "return nil or", 1)), (base:gsub("\n", "\n\n", 1)), (base:gsub("^[^\n]*\n", "")),
  }
  for index, other in ipairs(planted) do
    assert(Codegen.compared(other) ~= Codegen.compared(base), "planted difference " .. tostring(index) .. " not told")
  end
end

local function test_the_options_of_cosmics_own_tree_are_its_declarations_and_ceilings_and_a_project_has_none_to_name()
  local own = assert(Pipeline.options("."))
  assert(#own.globals.sources == 2)
  assert((Ceilings.of(own.ceilings, "checked")["build/tree_checks.tl view_written"] or 0) > 0, "the tree's ceilings are not read")
  assert(next(own.ceilings.stages) ~= nil and own.types)
  assert(own.project == nil and own.ceilings.none == nil)
  -- A project's are the declarations the tool carries, which a worker's store of the modules a test reads does not: either the
  -- options are the project's, or the tool is told to boot again.
  local project, why = Pipeline.options("/nonexistent-project-root")
  if project == nil then
    assert(why:find("this tool carries no declarations of the standard library", 1, true) ~= nil, tostring(why))
  else
    assert(project.project == true and #project.globals.sources == 2 and project.ceilings.none == true)
  end
end

local function test_the_options_of_a_project_are_the_texts_it_is_given_and_no_ceiling()
  local project = Pipeline.project({ prelude = "do\n   global interface any\n   end\nend\n", stdlib = "do\nend\n" })
  assert(project.project == true and project.types and project.ceilings.none == true)
  assert(next(project.ceilings.stages) == nil, "a project has no ceilings")
  assert(#project.globals.sources == 2)
  local stdlib = assert(project.globals.sources[2])
  assert(stdlib.filename == "checker/stdlib.d.tl" and stdlib.module == "checker.stdlib")
end

local function test_a_lone_file_takes_the_declarations_the_tool_carries_and_no_ceiling()
  local lone, why = Pipeline.alone()
  if lone == nil then
    assert(why:find("this tool carries no declarations of the standard library", 1, true) ~= nil, tostring(why))
  else
    assert(lone.project == true and #lone.globals.sources == 2 and lone.ceilings.none == true)
  end
end

local function test_a_lone_file_is_checked_with_no_ceiling_and_written_as_lua_that_runs()
  local made = assert(Pipeline.lone("script.tl", "local function twice(n: integer): integer\n  return n * 2\nend\nreturn twice(21)\n", options("")))
  assert(value_of(made) == 42, made)
  -- what it returns is its entry point, which no declaration describes
  local entry = assert(Pipeline.lone("entry.tl", "return function(): integer\n  return 7\nend\n", options("")))
  assert(entry:find("return function", 1, true) ~= nil, entry)
end

local function test_a_lone_file_is_refused_for_an_error_a_warning_and_a_syntax_error_in_the_checkers_words()
  local code, why = Pipeline.lone("bad.tl", "local n: string = 1\nreturn n\n", options(""))
  assert(code == nil and why:find("^bad.tl:1:") ~= nil and why:find("(not_assignable)", 1, true) ~= nil, tostring(why))
  -- a file alone has no ceilings to raise: its refusal never speaks of a pin
  assert(why:find("bad.tl: 1 error of not_assignable in its bodies; follow the fix above", 1, true) ~= nil, why)
  assert(why:find("pin", 1, true) == nil, why)
  -- a warning refuses as an error does
  local warned, warning = Pipeline.lone("warn.tl", "local unused = 1\nreturn 2\n", options(""))
  assert(warned == nil and warning:find("^warn.tl:1:7: ") ~= nil and warning:find("(unused_variable)", 1, true) ~= nil, tostring(warning))
  -- the entry point is the one error allowed: another beside it is told
  local both, told = Pipeline.lone("both.tl", "local n: string = 1\nreturn function(): integer\n  return n\nend\n", options(""))
  assert(both == nil and told:find("(not_assignable)", 1, true) ~= nil and told:find("(export_not_declared)", 1, true) == nil, tostring(told))
  -- a text that does not parse is told in the words of the translation
  local broken, syntax = Pipeline.lone("tuple.tl", "local t: {{string, integer}}\nreturn t\n", options(""))
  assert(broken == nil and syntax:find("^tuple.tl:1:") ~= nil and syntax:find("(tuple_type)", 1, true) ~= nil, tostring(syntax))
end

local function test_a_lone_file_keeps_an_import_it_never_reads_and_a_module_of_the_tree_does_not()
  local text = "local type _shape = require(\"cosmic.shape\")\nreturn 7\n"
  local kept = assert(Pipeline.lone("script.tl", text, options("")))
  assert(kept:find("require(\"cosmic.shape\")", 1, true) ~= nil, kept)
  local served = assert(generated(text, EXPORT))
  assert(served.lua:find("require", 1, true) == nil, served.lua)
end

--- A project's error is listed without the pin it has not got, and cosmic's own with it.
local function test_a_project_is_told_its_errors_without_a_pin_to_raise()
  local source = "local n: string = 1\nreturn n\n"
  local project = Pipeline.project({ prelude = "do\nend\n", stdlib = "do\nend\n" })
  local made, why = Pipeline.generate(module_of("m", "m.tl", "module", source, {}),
    Pipeline.over({ { "m.tl", source } }, { ["m.tl"] = "module" }, project))
  assert(made == nil)
  assert(why:find("(not_assignable)", 1, true) ~= nil and
      why:find("1 error of not_assignable in its bodies; follow the fix above", 1, true) ~= nil, tostring(why))
  assert(why:find("pinned", 1, true) == nil and why:find("ceilings.txt", 1, true) == nil, tostring(why))
  local _, own_why = generated(source)
  assert(own_why:find("1 error of not_assignable in its bodies, pinned 0; follow the fix above rather than " ..
      "raise the pin", 1, true) ~= nil, tostring(own_why))
end

--- The error-slot rules bind a project in the new mode: the fork holds only cosmic's own tree to them, and the pipeline holds
--- every module to them ([`Pipeline.generate`] does not ask whether the tree is cosmic's), as the owner decided: a project gets
--- the full checker.
local function test_a_project_is_held_to_the_error_slot_rules()
  local project = Pipeline.project({ prelude = "do\nend\n", stdlib = "do\nend\n" })
  local breach = table.concat({
    "local record M",
    "end",
    "function M.of(s: string): string, string",
    "  return s, \"\"",
    "end",
    "return M",
    "",
  }, "\n")
  local made, why = Pipeline.generate(module_of("m", "m.tl", "module", breach, {}),
    Pipeline.over({ { "m.tl", breach } }, { ["m.tl"] = "module" }, project))
  assert(made == nil and why:find("M.of: an exported function answers one result", 1, true) ~= nil, tostring(why))
  assert(why:find("pinned", 1, true) == nil, tostring(why))
  -- the same function answering a value or a reason is held
  local fine = table.concat({
    "local record M",
    "end",
    "function M.of(s: string): string | nil, string",
    "  if s == \"\" then",
    "    return nil, \"empty\"",
    "  end",
    "  return s, \"\"",
    "end",
    "return M",
    "",
  }, "\n")
  local held, held_why = Pipeline.generate(module_of("m", "m.tl", "module", fine, {}),
    Pipeline.over({ { "m.tl", fine } }, { ["m.tl"] = "module" }, project))
  assert(held ~= nil, tostring(held_why))
end

--- A boot names the code that reads from the tree it stages, since the release that runs it carries another: the modules the
--- pipeline reaches, and no other, once the tree is parsed.
local function test_the_code_that_reads_is_named_from_the_staged_tree(tmp: string)
  local root = tmp .. "/named"
  local function write(path: string, text: string)
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
    assert(Fs.write(root .. "/" .. path, text))
  end
  write("build/pipeline.tl", "local Reader = require(\"build.reader\")\nreturn Reader\n")
  write("build/reader.tl", "local Check = require(\"lang.check\")\nreturn Check\n")
  write("lang/check.tl", "return 1\n")
  write("build/other.tl", "return 2\n")
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local unparsed, why = Pipeline.coded_of("tool", handle.db)
  assert(unparsed == nil and why:find("is not parsed yet", 1, true) ~= nil, tostring(why))
  assert(importer.derive(handle, false, built, nil, nil, nil, nil))
  local first = assert(Pipeline.coded_of("tool", handle.db))
  assert(#first == 64 and Pipeline.coded_of("another tool", handle.db) ~= first, "the tool is no part of the identity")
  local function again(path: string, text: string): string
    write(path, text)
    assert(work.stage(handle, false))
    assert(importer.derive(handle, false, built, nil, nil, nil, nil))
    return (assert(Pipeline.coded_of("tool", handle.db)))
  end
  -- a module the pipeline does not reach moves nothing; one it reaches, directly or not, moves it
  assert(again("build/other.tl", "return 3\n") == first, "a module the pipeline does not reach moved the identity")
  local reader = again("build/reader.tl", "local Check = require(\"lang.check\")\nreturn Check, 1\n")
  assert(reader ~= first, "an edit to a module the pipeline requires did not move the identity")
  assert(again("lang/check.tl", "return 4\n") ~= reader, "an edit to a module it reaches through another did not move the identity")
  assert(work.close(handle))
end

--- A project's file of the fork's name is a module of it, and cosmic's own tree leaves the fork's checker out.
local function test_a_build_over_a_project_keeps_the_file_of_the_forks_name_and_cosmics_tree_leaves_it_out()
  local entries: {{string}} = { { "checker/tl.tl", "return 1\n" } }
  local project = Pipeline.over(entries, {}, Pipeline.project({ prelude = "do\nend\n", stdlib = "do\nend\n" }))
  assert(project.build:parsed("checker.tl") ~= nil, "a project's checker/tl.tl is no module of it")
  local own = Pipeline.over(entries, {}, options(""))
  assert(own.build:parsed("checker.tl") == nil, "cosmic's tree holds the fork's checker as a module")
end

--- A tool is written from a tree the new checker refused in the files of the residue alone: any other refusal stops it.
local function test_a_tool_is_not_written_from_a_tree_refused_beyond_the_residue()
  local refused: {string} = {
    "cosmic/removed_example.tl:279:3: `function Friendly:greet` is not in the grammar (method_in_record): declare it inside its class",
    "build/a.tl: the compiler refused it\nbuild/a.tl:1:1: nil is given (nil_not_allowed): fix",
    "doc/guides/project.md:713:3: `function Kv.Lru.get` has more than one dot (function_path): assign the function to the field",
    "build/b.tl: not compiled: it requires a, which the new checker refused",
  }
  local rest = Pipeline.unexpected(refused)
  assert(#rest == 2 and (rest[1] or ""):find("^build/a.tl: the compiler refused it") ~= nil and
      (rest[2] or ""):find("^build/b.tl: not compiled") ~= nil, table.concat(rest, "|"))
  assert(#Pipeline.unexpected({}) == 0)
  -- the residue is the files [`Pipeline.residue`] names: a refusal of one of them is nothing else
  local residue = Pipeline.residue()
  assert(residue["cosmic/removed_example.tl"] ~= nil and residue["doc/guides/project.md"] ~= nil)
  assert(#Pipeline.unexpected({ "cosmic/removed_example.tl:1:1: refused (some_code): fix",
    "doc/guides/project.md:1:1: refused (some_code): fix" }) == 0)
end

local function test_the_standard_library_the_tree_does_not_hold_is_the_binarys_own()
  local carried = Pipeline.carried()
  local source = assert(carried("cosmic.string"))
  assert(source.translate and not source.checked and source.dialect == "tl" and source.filename == "cosmic/string.tl")
  -- the stub, which a project's checker reads in place of the source
  assert(source.text == assert(teal.standard_text("cosmic.string")).text)
  assert(carried("not.a.module") == nil)
end

local function test_a_staged_project_is_built_from_its_inputs_and_compiles_to_what_the_pieces_say(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/doc/guides"))
  assert(Fs.write(root .. "/m.tl", table.concat({
    "local record M", "  double: function(integer): integer", "end",
    "local m: M = { double = function(n: integer): integer return n * 2 end }", "return m", "",
  }, "\n")))
  assert(Fs.write(root .. "/m_test.tl",
    "local m = require(\"m\")\nlocal function test_m()\n  assert(m.double(21) == 42)\nend\n"))
  assert(Fs.write(root .. "/doc/guides/g.md", "# g\n\n```teal\nlocal x = 1\nassert(x == 1)\n```\n"))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  assert(importer.derive(handle, false, built))
  local pipeline = assert(Pipeline.build(handle.db, options("")))
  local modules = assert(compilation.collect(handle.db))
  local seen: {string: boolean} = {}
  for _, m in ipairs(modules) do
    seen[m.path] = true
    if m.path == "m" or m.path == "m_test" then
      local made = assert(Pipeline.generate(m, pipeline))
      assert(#made.bytecode > 0)
      if m.path == "m" then
        assert((value_of(made.lua) as {string: function(integer): integer}).double(21) == 42)
      else
        assert(made.lua:find("return { test_m = test_m }", 1, true) ~= nil)
      end
    end
  end
  assert(seen["m"] and seen["m_test"] and seen["doc.guides.g"], "the guide is a module of the project")
  -- the guide is the test module its stage derived, named for its file
  local guide = assert(pipeline.build:parsed("doc.guides.g"))
  assert(guide.source.filename == "doc/guides/g.md" and guide.source.tests and guide.source.translate)
  assert(work.close(handle))
end

-- what the compile holds a module to besides the checker

--- What the fork's contracts say of `source` as the file `m.tl` (the problems, one to a line), with the fixture's prelude of
--- functions that fail.
local function fork_says(source: string): string
  local said = Fixture.fork(Fixture.PRELUDE .. source .. "\nuse(get, put, name, pair, complain, lead, maybe, sget, log)\n")
  local lines: {string} = {}
  for _, line in ipairs(said.problems) do
    lines[#lines + 1] = (line:gsub("^x%.tl:(%d+):", "m.tl:%1:"))
  end
  return table.concat(lines, "\n")
end

--- The contract refusals of the compile for `source`: what it says of the module beyond the prelude's lines.
local function compile_says(source: string): string
  local text = Fixture.PRELUDE .. source .. "\nuse(get, put, name, pair, complain, lead, maybe, sget, log)\n"
  local made, why = generated(text, "", "module")
  assert(made == nil, "the compile accepts:\n" .. source)
  return why
end

--- Programs the fork's discipline refuses, each refused by the compile with the fork's words, in the fork's order.
local function test_the_compile_refuses_what_the_forks_discipline_refuses_with_its_words()
  local programs: {string} = {
    "local v = get()\nuse(v)",
    "put()",
    "use(get(), 1)",
    "local function f(): integer | nil, string\n  local v, err = get()\n  if v == nil then return 0, err end\n  return v, ''\nend\nuse(f)",
    "local function f(): string | nil, integer\n  return nil, 127\nend\nuse(f)",
    "if get() then use(1) end",
    "use((get()))",
  }
  for _, program in ipairs(programs) do
    local want = fork_says(program)
    assert(want ~= "", "the fork finds nothing in:\n" .. program)
    local got = compile_says(program)
    assert(got == want, "in:\n" .. program .. "\nthe fork says:\n" .. want .. "\nthe compile says:\n" .. got)
  end
end

local function test_a_unjudged_compile_keeps_a_breach_for_the_tool_it_builds_and_marks_it_refused()
  local text = Fixture.PRELUDE .. "local v = get()\nuse(v)\nuse(get, put, name, pair, complain, lead, maybe, sget, log)\n"
  local pipeline = Pipeline.over({ { "m.tl", text } }, { ["m.tl"] = "module" }, options(""))
  local m = module_of("m", "m.tl", "module", text, {})
  local kept = assert(Pipeline.generate(m, pipeline, false, false))
  assert(kept.refused and #kept.lua > 0)
  local pipeline_again = Pipeline.over({ { "m.tl", text } }, { ["m.tl"] = "module" }, options(""))
  local refused, why = Pipeline.generate(m, pipeline_again, false, true)
  assert(refused == nil and why:find("its error slot is dropped", 1, true) ~= nil, tostring(why))
end

local function test_a_refused_call_points_to_the_worked_example_when_the_docs_hold_it()
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  assert(Sqlite.run(db,
    "INSERT INTO modules (path, file, kind, source_hash, key, source, bytecode, tests) " ..
      "VALUES ('cosmic.fs', 'cosmic/fs.tl', 'module', '', '', '', '', '')"))
  assert(Sqlite.run(db,
    "INSERT INTO examples (module, name, text, file, line, source) " ..
      "VALUES ('cosmic.fs', 'generics_functions_returns', 'Calls.', 'cosmic/fs.tl', 9, 'local x = 1')"))
  assert(db:exec("INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')"))
  local text = "local function f(a: integer): integer\n  return a\nend\nreturn f(1, 2)\n"
  local pipeline = Pipeline.over({ { "m.tl", text } }, { ["m.tl"] = "module" }, options(""))
  local m = module_of("m", "m.tl", "module", text, {})
  local bare, bare_why = Pipeline.generate(m, pipeline)
  assert(bare == nil and bare_why:find("(arity)", 1, true) ~= nil and not bare_why:find("see also", 1, true), tostring(bare_why))
  local pointed, why = Pipeline.generate(m, pipeline, false, true, function(): {Sqlite.Handle}, {boolean}
    return { db }, { false }
  end)
  assert(pointed == nil and why:find("(arity): ", 1, true) ~= nil and
      why:find(" -- see also: cosmic docs generics_functions_returns", 1, true) ~= nil, tostring(why))
end

local function test_a_guide_example_is_forgiven_the_shadowing_of_print_and_no_other_name()
  local function shadow(name: string): Driver.Problem
    return { code = "shadows", msg = "local `" .. name .. "` shadows the global `" .. name .. "`", fix = "", y = 1, x = 1, offset = 0 } as Driver.Problem
  end
  local result = { scope_errors = { shadow("print"), shadow("printer"), shadow("println") } } as Driver.Outcome
  Pipeline.discounted(result)
  assert(#result.scope_errors == 2 and result.scope_errors[1].msg:find("`printer`", 1, true) ~= nil and
      result.scope_errors[2].msg:find("`println`", 1, true) ~= nil)
end

local function test_a_test_or_an_example_or_a_generated_module_is_not_held_to_the_discipline()
  local text = Fixture.PRELUDE .. "local v = get()\nuse(v)\nuse(get, put, name, pair, complain, lead, maybe, sget, log)\n"
  for _, kind in ipairs({ "test", "example" }) do
    local made, why = generated(text, "", kind, kind == "test" and { "test_none" } or {})
    assert(made ~= nil or why:find("error slot", 1, true) == nil, tostring(why))
  end
end

--- A calls the checker gave no function is held to the ceiling of `[untyped]`, and a type error to its own.
local function test_a_call_the_checker_could_not_type_is_held_to_its_untyped_ceiling()
  local source = "local missing: string = 1\nlocal function f(): integer\n  return missing()\nend\nreturn f\n"
  local made, why = generated(source, "[checked]\nm.tl not_assignable 1\nm.tl not_callable 1\n")
  assert(made == nil and why:find("1 call the checker gave no function, which no rule of the discipline judged, pinned 0", 1, true) ~= nil,
    tostring(why))
  local allowed = generated(source, "[checked]\nm.tl not_assignable 1\nm.tl not_callable 1\n[untyped]\nm.tl 1\n")
  assert(allowed ~= nil)
end

local function test_a_standard_library_module_is_held_to_its_stub()
  local source = table.concat({ "local record Box", "  n: integer", "  more: string", "end", "return Box", "" }, "\n")
  local stub = table.concat({ "local record Box", "  n: integer", "end", "return Box", "" }, "\n")
  local entries: {{string}} = { { "cosmic/box.tl", source } }
  local kinds: {string: string} = { ["cosmic/box.tl"] = "module" }
  local pipeline = Pipeline.over(entries, kinds, options(""), { ["cosmic.box"] = stub })
  local m = module_of("cosmic.box", "cosmic/box.tl", "module", source, {})
  m.stub = { text = stub, pruned = true }
  local made, why = Pipeline.generate(m, pipeline)
  assert(made == nil and why:find("cosmic/box.tl: the stub a project's checker reads in its place", 1, true) == 1, tostring(why))
  assert(why:find("Box", 1, true) ~= nil, tostring(why))
  -- a stub that keeps every statement is no stub
  local unpruned = module_of("cosmic.box", "cosmic/box.tl", "module", source, {})
  unpruned.stub = { text = source, pruned = false }
  local whole, whole_why = Pipeline.generate(unpruned, Pipeline.over(entries, kinds, options(""), { ["cosmic.box"] = stub }))
  assert(whole == nil and whole_why:find("its stub keeps every statement", 1, true) ~= nil, tostring(whole_why))
  -- a run that does not judge keeps the compile for the tool it builds, marked
  local kept = assert(Pipeline.generate(m, Pipeline.over(entries, kinds, options(""), { ["cosmic.box"] = stub }), false, false))
  assert(kept.refused)
  -- the stub that types the module as its source does holds it
  local fine = module_of("cosmic.box", "cosmic/box.tl", "module", source, {})
  fine.stub = { text = source, pruned = true }
  local held = assert(Pipeline.generate(fine, Pipeline.over(entries, kinds, options(""), { ["cosmic.box"] = source })))
  assert(not held.refused)
end

--- Whether the fork's checker types `stub` otherwise than `source`: the difference cosmic's own build refuses a stub for.
local function fork_stub_differs(source: string, stub: string): boolean
  local function type_of(text: string): any
    local env = assert(built.new_env({ defaults = teal.defaults() }))
    return built.check_string(text, env, "m.tl", "tl").type
  end
  return Stub.difference(type_of(source), type_of(stub)) ~= nil
end

local function test_a_stub_that_types_a_module_otherwise_than_its_source_is_refused_as_the_fork_refuses_it()
  local cases: {{string}} = {
    { "local record Box\n  n: integer\n  more: string\nend\nreturn Box\n", "local record Box\n  n: integer\nend\nreturn Box\n" },
    { "local record Box\n  f: function(string): integer\nend\nreturn Box\n",
      "local record Box\n  f: function(string): string\nend\nreturn Box\n" },
    { "local record Box\n  record Inner\n    x: integer\n  end\n  inner: Inner\nend\nreturn Box\n",
      "local record Box\n  record Inner\n    x: string\n  end\n  inner: Inner\nend\nreturn Box\n" },
    { "local record Box\n  items: {integer}\nend\nreturn Box\n", "local record Box\n  items: {string}\nend\nreturn Box\n" },
    { "local record Box\n  n: integer\nend\nreturn Box\n", "local record Box\n  n: integer\n  extra: boolean\nend\nreturn Box\n" },
  }
  for _, case in ipairs(cases) do
    local source, stub = assert(case[1]), assert(case[2])
    assert(fork_stub_differs(source, stub), "the fork finds no difference in:\n" .. stub)
    local entries: {{string}} = { { "cosmic/box.tl", source } }
    local kinds: {string: string} = { ["cosmic/box.tl"] = "module" }
    local m = module_of("cosmic.box", "cosmic/box.tl", "module", source, {})
    m.stub = { text = stub, pruned = true }
    local made, why = Pipeline.generate(m, Pipeline.over(entries, kinds, options(""), { ["cosmic.box"] = stub }))
    assert(made == nil and why:find("the stub a project's checker reads in its place", 1, true) ~= nil, "accepted:\n" .. stub)
  end
end

local function test_the_record_field_uses_of_a_module_are_found_through_the_types_the_checker_gave()
  local entries: {{string}} = {
    { "cosmic/shape_of.tl", table.concat({
      "local record Shape", "  record Point", "    x: integer", "  end", "  origin: function(): Shape.Point", "end",
      "function Shape.origin(): Shape.Point", "  return { x = 0 }", "end", "return Shape", "" }, "\n") },
    { "user.tl", table.concat({
      'local Shape = require("cosmic.shape_of")', "local p = Shape.origin()", "return p.x + 1", "" }, "\n") },
  }
  local pipeline = Pipeline.over(entries, { ["cosmic/shape_of.tl"] = "module", ["user.tl"] = "module" },
    options("[checked]\nuser.tl export_not_declared 1\n"))
  local user = assert(entries[2])
  local m = module_of("user", "user.tl", "module", assert(user[2]), {})
  local made = assert(Pipeline.generate(m, pipeline))
  local use = assert(made.references[1], "no use found")
  assert(#made.references == 1 and use.module == "cosmic.shape_of" and use.member == "Point.x" and use.line == 3,
    #made.references .. " uses")
end

local function test_a_record_test_is_written_as_the_fork_writes_it_for_the_tree_and_refused_for_a_program_without_a_ceiling()
  local source = "local record R\n  n: integer\nend\nlocal function f(v: R | string): boolean\n  if v is R then\n    return v.n > 0\n  end\n" ..
    "  return false\nend\nreturn f\n"
  local made = assert(generated(source, "[checked]\nm.tl is_on_record 1\nm.tl export_not_declared 1\n"))
  assert(made.lua:find('if type(v) == "table" then', 1, true) ~= nil, made.lua)
  local f = value_of(made.lua) as function(any): boolean
  assert(f({ n = 1 }) == true and f("s") == false)
  -- the ceiling is held: a test the pins do not count is refused
  local over, why = generated(source, "[checked]\nm.tl export_not_declared 1\n")
  assert(over == nil and why:find("(is_on_record)", 1, true) ~= nil, tostring(why))
end

-- In the closure, so the store the worker is given carries the module the build reads the stub of ([`Pipeline.carried`]).
local type _shape = require("cosmic.shape")

local function test_into_answers_the_records_type_and_no_annotation_can_say_another()
  local function with_annotation(annotation: string): string
    return table.concat({
      'local Shape = require("cosmic.shape")',
      "local record R",
      "  n: integer",
      "end",
      "local record Other",
      "  s: string",
      "end",
      'local S = Shape.record_of("R")',
      "local got, err: " .. annotation .. " | nil, string = S:into({ n = 1 })",
      'local other: Other = { s = "x" }',
      "local function show(a: R | nil, b: string, c: Other): string",
      "  return tostring(a) .. b .. c.s",
      "end",
      "return show(got, err, other)",
      "",
    }, "\n")
  end
  local carried = options("[checked]\nm.tl export_not_declared 1\n")
  carried.standard = Pipeline.carried()
  local function compiled(annotation: string): compilation.Generated | nil, string
    local source = with_annotation(annotation)
    local pipeline = Pipeline.over({ { "m.tl", source } }, { ["m.tl"] = "module" }, carried)
    return Pipeline.generate(module_of("m", "m.tl", "module", source, {}), pipeline)
  end
  local made, trouble = compiled("R")
  assert(made ~= nil, tostring(trouble))
  local other, refusal = compiled("Other")
  assert(other == nil, "a spec built from R answered an Other")
  assert(refusal:find("Other", 1, true) ~= nil and refusal:find("R", 1, true) ~= nil, tostring(refusal))
end

-- a program the fork's compiler refuses is refused

--- Whether the fork's compiler refuses `source`: a syntax error, a type error or a warning, as the build refuses a module for.
local function fork_refuses(source: string): boolean
  local fork = teal.lazy()
  teal.serve_standard(fork)
  local env = assert(fork.new_env({ defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" } }))
  local code, result = fork.gen(source, env, nil, "tl")
  return code == nil or #result.syntax_errors > 0 or #result.type_errors > 0 or #result.warnings > 0
end

local function test_a_program_the_fork_refuses_for_its_types_is_refused_with_the_checkers_words_through_the_renderer()
  local programs: {{string}} = {
    { "local n: string = 1\nreturn n\n", "(not_assignable)" },
    { "local function f(a: integer): integer\n  return a\nend\nreturn f(1, 2)\n", "(arity)" },
    { "return undefined_name\n", "(unknown_variable)" },
    { "local record R\n  n: integer\nend\nlocal r: R = { n = 1 }\nreturn r.m\n", "(field_unknown)" },
    { "local unused = 1\nreturn 2\n", "(unused" },
    { "local x: integer = \"a\"\nreturn x\n", "(not_assignable)" },
    { "local function f(a: integer): string\n  return a\nend\nreturn f(1)\n", "(not_assignable)" },
    { "local t: {string} = { 1 }\nreturn t\n", "(not_assignable)" },
    { "local function f(a: string): integer\n  return #a\nend\nreturn f(1)\n", "(not_assignable)" },
    { "local s: string? = nil\nreturn #s\n", "(nil_not_allowed)" },
    { "local record R\n  n: integer\nend\nlocal r: R = { n = 1, m = 2 }\nreturn r\n", "(literal_unknown)" },
  }
  for _, case in ipairs(programs) do
    local source, wanted = assert(case[1]), assert(case[2])
    assert(fork_refuses(source), "the fork accepts:\n" .. source)
    local made, why = generated(source)
    assert(made == nil, "the compile accepts:\n" .. source)
    -- the renderer's layout: the file, the line, the column, the words, the code and the fix
    assert(why:find("^m.tl: the compiler refused it\nm.tl:%d+:%d+: .+ %([%w_]+%): ") ~= nil, why)
    assert(why:find(wanted, 1, true) ~= nil, "expected " .. wanted .. " in:\n" .. why)
  end
end
