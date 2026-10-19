--- The tests of [`build.pipeline`]: a module of the fork's Teal read, checked against its ceilings and written as Lua and bytecode by the
--- new checker, the way [`build.compilation`]'s `generate` answers for the fork's compiler. The Lua is run, and compared
--- with what the generator writes alone ([`lang.codegen`]) and with the fork's, over the files of the tree.
local Ceilings = require("build.ceilings")
local Codegen = require("lang.codegen")
local CompileGrammar = require("build.compile_grammar")
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Pipeline = require("build.pipeline")
local Programs = require("lang.check_programs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local compilation = require("build.compilation")
local compile = require("build.compile")
local importer = require("build.importer")
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
    ceilings = ceilings(pins), types = false, standard = Driver.stubs(STANDARD),
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
    "[checked]\nm.tl cast_refused 1\nm.tl any_use 1\n"))
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
  assert(next(own.ceilings.stages) ~= nil and not own.types)
  local project, why = Pipeline.options("/nonexistent-project-root")
  assert(project == nil and why:find("carries no declaration of the standard library", 1, true) ~= nil, tostring(why))
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
