--- `cosmic compile --grammar new` (build/compile.tl, build/compile_grammar.tl): files in the new checker's
--- grammar are lexed, parsed, scoped, lowered, checked and written as Lua, and the Lua is written despite type
--- errors, as for Teal. The grammar is named, never guessed. build/compile_lang_test.tl compiles the checker's
--- own source with it.

local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local compile = require("build.compile")
local Grammar = require("build.compile_grammar")

Test.policy{}

local record Ran
  mut code: integer
  mut out: string
  mut err: string
end

local type IsColor = function(string): boolean
local type Kinder = function(any): string

--- The directory of the test's files, which a run takes as `--root`.
local where: {string} = {}

--- One run of `cosmic compile` with `words`, in the new grammar unless a word says otherwise.
local function run(words: {string}): Ran
  local argv: mut {string} = { "compile", "--root", where[1] or "" }
  local at = 4
  local named = false
  for _, word in ipairs(words) do named = named or word == "--grammar" end
  if not named then
    argv[at], argv[at + 1] = "--grammar", "new"
    at = at + 2
  end
  for index, word in ipairs(words) do argv[index + at - 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = compile.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
  })
  return ran
end

local function file(tmp: string, name: string, text: string): string
  where[1] = tmp
  local path = tmp .. "/" .. name
  assert(Fs.mkdirs((path:gsub("/[^/]*$", ""))))
  assert(Fs.write(path, text))
  return path
end

--- The Lua `text` runs as, and what it returns.
local function value_of(code: string): any
  local chunk = assert(load(code, "=compiled"))
  return chunk()
end

--- The module `name` of the files written to `dir`, run with a `require` that finds the others there.
local function module_of_dir(dir: string, name: string): any
  local env: mut {string: any} = {}
  local made: mut {string: any} = {}
  env["require"] = function(wanted: string): any
    if made[wanted] == nil then
      local text = (assert(Fs.read(dir .. "/" .. wanted .. ".lua")))
      made[wanted] = assert(load(text, "=" .. wanted, "t", env))()
    end
    return made[wanted]
  end
  setmetatable(env, { __index = _G })
  local text = (assert(Fs.read(dir .. "/" .. name .. ".lua")))
  return assert(load(text, "=" .. name, "t", env))()
end

local function test_a_type_error_is_reported_and_the_lua_is_written_line_for_line(tmp: string)
  local path = file(tmp, "typed.tl", "local count = 1\n\nlocal s: string = count\nreturn s\n")
  local ran = run({ "--errors", path })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("typed.tl:3:", 1, true) and ran.err:find("(not_assignable)", 1, true), ran.err)
  assert(ran.err:find("1 type error", 1, true) and ran.err:find("written anyway", 1, true), ran.err)
  local lines: mut {string} = {}
  for line in (ran.out .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  assert(lines[1] == "local count = 1" and lines[3] == "local s = count" and lines[4] == "return s", ran.out)
  assert(value_of(ran.out) == 1)
end

local function test_the_count_alone_is_reported_without_errors(tmp: string)
  local path = file(tmp, "typed.tl", "local s: string = 1\nreturn s\n")
  local ran = run({ path })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("1 type error", 1, true) and ran.err:find("--errors", 1, true), ran.err)
  assert(not ran.err:find("typed.tl:1:", 1, true), ran.err)
end

--- A file compiled alone keeps the `require` of a type import it never reads as a value, as the fork writes it; only the build
--- that serves every module drops it ([`lang.codegen`]'s `served`, `Pipeline.generate`).
local function test_a_file_compiled_alone_keeps_the_require_of_an_import_it_never_reads(tmp: string)
  local path = file(tmp, "alone.tl", "local type _fs = require(\"cosmic.fs\")\nreturn 7\n")
  local ran = run({ path })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find('local _fs = require("cosmic.fs")', 1, true) ~= nil, ran.out)
end

--- The forms the grammar adds are written as the Lua they mean.
local function test_the_forms_of_the_new_grammar_run_as_what_they_mean(tmp: string)
  local text = table.concat({
    "local enum Color",
    "  \"red\"",
    "  \"green\"",
    "end",
    "local function name(c: Color): string",
    "  return if c == \"red\" then \"warm\" else \"cool\" end",
    "end",
    "local out: {string} = {}",
    "for i = 1, 4 do",
    "  if i == 2 then continue end",
    "  out[#out + 1] = tostring(i)",
    "end",
    "local v: Color = \"green\"",
    "return name(v) .. table.concat(out, \",\")",
    "",
  }, "\n")
  local ran = run({ file(tmp, "forms.tl", text) })
  assert(ran.code == 0, ran.err)
  assert(value_of(ran.out) == "cool1,3,4", ran.out)
end

local function test_a_syntax_error_is_refused_naming_the_file_and_line_and_writes_nothing(tmp: string)
  local good = file(tmp, "good.tl", "return 1\n")
  local bad = file(tmp, "bad.tl", "local a = 1\nlocal b = = 2\nreturn a\n")
  local ran = run({ "-o", tmp .. "/out", good, bad })
  assert(ran.code == 2, ran.code)
  assert(ran.err:find("bad.tl:2:", 1, true) and ran.err:find("syntax error", 1, true), ran.err)
  assert(not ran.err:find("good.tl", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/good.lua") == false and Fs.exists(tmp .. "/out/bad.lua") == false)
end

--- Teal's `T | nil` is a form the new grammar cuts, and the refusal says what to write.
local function test_a_form_the_grammar_cuts_is_a_syntax_error(tmp: string)
  local ran = run({ file(tmp, "cut.tl", "local x: string | nil = nil\nreturn x\n") })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cut.tl:1:", 1, true) and ran.err:find("(nil_union)", 1, true), ran.err)
end

--- The grammar is the new one, named or not: the fork's is refused naming `cosmic migrate`, and a text in the fork's forms is a
--- syntax error.
local function test_the_grammar_is_new_and_teal_is_refused(tmp: string)
  local new_only = file(tmp, "new.tl", "for i = 1, 2 do\n  if i == 1 then continue end\nend\nreturn 1\n")
  local teal_only = file(tmp, "teal.tl", "local x: string | nil = nil\nreturn x\n")
  local as_teal = run({ "--grammar", "teal", new_only })
  assert(as_teal.code == 2, as_teal.err)
  assert(as_teal.err:find("the fork's grammar is gone", 1, true) and as_teal.err:find("cosmic migrate", 1, true), as_teal.err)
  local as_new = run({ teal_only })
  assert(as_new.code == 2, as_new.err)
  assert(as_new.err:find("teal.tl:1:", 1, true), as_new.err)
  local fine = run({ new_only })
  assert(fine.code == 0, fine.err)
end

local function test_a_grammar_that_is_neither_is_refused(tmp: string)
  local ran = run({ "--grammar", "lua", file(tmp, "x.tl", "return 1\n") })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("--grammar names new, not lua", 1, true), ran.err)
end

--- A module of the binary's own is one the new checker cannot declare: typed `invalid`, and said so.
local function test_a_cosmic_module_is_invalid_and_reported(tmp: string)
  local text = "local Fs = require(\"cosmic.fs\")\nlocal data = Fs.read(\"x\")\nlocal n: integer = data\nreturn n\n"
  local ran = run({ "--errors", file(tmp, "uses.tl", text) })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("uses.tl:1:", 1, true) and ran.err:find("(unchecked_binding)", 1, true), ran.err)
  assert(ran.err:find("cosmic.fs", 1, true), ran.err)
  assert(ran.out:find("require(\"cosmic.fs\")", 1, true), ran.out)
  -- Nothing is typed from it, so the mistake after it is not reported on top: `invalid` is one report.
  assert(not ran.err:find("uses.tl:3:", 1, true), ran.err)
end

--- A cosmic module given as a file is the module the file names, and is checked from it.
local function test_a_cosmic_module_given_as_a_file_is_typed_from_it(tmp: string)
  local lib = file(tmp, "cosmic/tiny.tl",
    "local record Tiny\n  n: integer\nend\nreturn Tiny\n")
  local user = file(tmp, "user.tl",
    "local Tiny = require(\"cosmic.tiny\")\nlocal t: Tiny = { n = \"text\" }\nreturn t\n")
  local ran = run({ "--errors", "-o", tmp .. "/out", lib, user })
  assert(ran.code == 0, ran.err)
  assert(not ran.err:find("unchecked_binding", 1, true), ran.err)
  assert(ran.err:find("user.tl:2:", 1, true), ran.err)
end

local function test_a_require_nothing_names_says_how_to_fix_it(tmp: string)
  local ran = run({ "--errors", file(tmp, "main.tl", "local lib = require(\"lib\")\nreturn lib\n") })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("(require_unknown)", 1, true), ran.err)
  assert(ran.err:find("--root", 1, true) and ran.err:find("pass that file", 1, true), ran.err)
end

--- A file given is the module its path below the root names, whichever order the files come in.
local function test_a_require_of_a_given_file_is_typed_from_it_in_any_order(tmp: string)
  local lib = file(tmp, "pkg/lib.tl", "local record Box\n  n: integer\nend\nreturn Box\n")
  local main = file(tmp, "main.tl",
    "local Box = require(\"pkg.lib\")\nlocal b: Box = { n = \"text\" }\nreturn b\n")
  for _, order in ipairs({ { lib, main }, { main, lib } }) do
    local words: mut {string} = { "--errors", "-o", tmp .. "/out" }
    for _, path in ipairs(order) do words[#words + 1] = path end
    local ran = run(words)
    assert(ran.code == 0, ran.err)
    assert(ran.err:find("main.tl:2:", 1, true) and not ran.err:find("require_unknown", 1, true), ran.err)
    assert(Fs.exists(tmp .. "/out/lib.lua") == true and Fs.exists(tmp .. "/out/main.lua") == true)
  end
end

--- The globals are the declaration files': none given, `print` is not declared, one given, it is.
local function test_the_globals_are_those_the_declaration_files_declare(tmp: string)
  local decl = file(tmp, "std.d.tl", "global print: function(...: any)\n")
  local user = file(tmp, "user.tl", "print(\"hi\")\nlocal record Done\nend\nreturn Done\n")
  local without = run({ "--errors", user })
  assert(without.code == 0, without.err)
  assert(without.err:find("user.tl:1:", 1, true) and without.err:find("(unknown_variable)", 1, true), without.err)
  local with = run({ "--errors", "-o", tmp .. "/out", decl, user })
  assert(with.code == 0, with.err)
  assert(not with.err:find("user.tl", 1, true), with.err)
  assert(with.err:find("std.d.tl: declares globals and types and has no Lua", 1, true), with.err)
  assert(Fs.exists(tmp .. "/out/user.lua") == true and Fs.exists(tmp .. "/out/std.lua") == false)
end

--- A syntax error in a declaration file refuses the run, as one in a program does.
local function test_a_syntax_error_in_a_declaration_file_is_refused(tmp: string)
  local decl = file(tmp, "std.d.tl", "global print: function(...: any\n")
  local user = file(tmp, "user.tl", "return 1\n")
  local ran = run({ "-o", tmp .. "/out", decl, user })
  assert(ran.code == 2, ran.err)
  assert(ran.err:find("std.d.tl:2:1: expected `)`", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/user.lua") == false)
end

--- A declaration beside its source is one module, as in a build: a require reads the declaration, and the source is
--- compiled as the implementation. Two sources of one module are two files for it, which the program has one of.
local function test_a_declaration_beside_its_source_is_one_module_and_two_sources_are_refused(tmp: string)
  local decl = file(tmp, "foo.d.tl", "local record Foo\n  n: integer\nend\nreturn Foo\n")
  local source = file(tmp, "foo.tl", "local record Foo\n  n: integer\nend\nlocal f: Foo = { n = 1 }\nreturn f\n")
  local ran = run({ "-o", tmp .. "/out", decl, source })
  assert(ran.code == 0, ran.err)
  assert(Fs.exists(tmp .. "/out/foo.lua") == true)
  assert(Fs.exists(tmp .. "/out/foo.d.lua") == false)
  assert(Fs.mkdirs(tmp .. "/foo"))
  local nested = file(tmp, "foo/init.tl", "local n: integer = 1\nreturn n\n")
  local twice = run({ "-o", tmp .. "/out2", source, nested })
  assert(twice.code == 2, twice.err)
  assert(twice.err:find("both the module foo", 1, true), twice.err)
end

--- Two files that name each other's types: the one lowered first finds the other declared, not lowered.
local function test_a_cycle_between_given_files_names_each_others_types(tmp: string)
  local a = file(tmp, "a.tl", "local type B = require(\"b\")\nlocal record A\n  b: B?\nend\nreturn A\n")
  local b = file(tmp, "b.tl", "local type A = require(\"a\")\nlocal record B\n  a: A?\nend\nreturn B\n")
  local ran = run({ "--errors", "-o", tmp .. "/out", a, b })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(Fs.exists(tmp .. "/out/a.lua") == true and Fs.exists(tmp .. "/out/b.lua") == true)
end

--- A file is lowered after the files it requires, whichever order they are given in: the value a module
--- returns is typed once the module is lowered, and a module named first can need it.
local function test_a_module_is_checked_against_the_files_it_requires_given_after_it(tmp: string)
  local main = file(tmp, "main.tl", "local f = require(\"lib\")\nlocal s: string = f()\nreturn s\n")
  local lib = file(tmp, "lib.tl", "local function f(): integer\n  return 1\nend\nreturn f\n")
  local ran = run({ "--errors", "-o", tmp .. "/out", main, lib })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("main.tl:2:", 1, true) and ran.err:find("(not_assignable)", 1, true), ran.err)
end

--- The Lua is written from what the checker concluded: `v is Color` of a local enum tests the value, not
--- only that it is a string.
local function test_a_test_for_an_enum_is_a_test_for_its_values(tmp: string)
  local text = table.concat({
    "local enum Color",
    "  \"red\"",
    "  \"green\"",
    "end",
    "local function is_color(v: string): boolean",
    "  return v is Color",
    "end",
    "return is_color",
    "",
  }, "\n")
  local ran = run({ file(tmp, "enum.tl", text) })
  assert(ran.code == 0, ran.err)
  local test = value_of(ran.out)
  assert(test is IsColor, "not a function")
  assert(test("red") == true and test("blue") == false)
end

--- What the generator does not write yet is a refusal, since the Lua would lack it.
local function test_a_form_the_generator_refuses_writes_no_lua(tmp: string)
  local text = "local record Outer\n  class Inner\n    n: integer\n  end\nend\nreturn Outer\n"
  local ran = run({ "-o", tmp .. "/out", file(tmp, "nested.tl", text) })
  assert(ran.code == 2, ran.code)
  assert(ran.err:find("the generator wrote no Lua", 1, true) and ran.err:find("(class_nested_refused)", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/nested.lua") == false)
end

--- The errors of every stage are listed in the order of the source, whichever stage found them.
local function test_the_errors_of_every_stage_are_listed_in_source_order(tmp: string)
  local text = "local s: string = 1\nlocal list: {integer?} = {}\nreturn list\n"
  local ran = run({ "--errors", file(tmp, "order.tl", text) })
  assert(ran.code == 0, ran.err)
  local checked = ran.err:find("order.tl:1:", 1, true)
  local declared = ran.err:find("(array_of_optional)", 1, true)
  assert(checked ~= nil and declared ~= nil and checked < declared, ran.err)
end

--- No file is scoped, lowered or checked once any has a syntax error.
local function test_a_syntax_error_stops_before_any_other_stage(tmp: string)
  local made = Grammar.compile({
    { path = "a.tl", relative = "a.tl", text = "local s: string = 1\nreturn s\n", declaration = false },
    { path = "b.tl", relative = "b.tl", text = "local = 2\n", declaration = false },
  })
  assert(#made == 2)
  for _, compiled in ipairs(made) do
    assert(compiled.code == nil and #compiled.type_errors == 0, compiled.path .. " went past the syntax error")
    assert((#compiled.syntax_errors > 0) == (compiled.path == "b.tl"), compiled.path)
  end
  assert(tmp ~= "")
end

--- A name of another file that stands for a primitive is a test for that primitive: the generator reads one file
--- and cannot see the alias, so the checker's answer reaches it.
local function test_a_test_for_an_alias_of_another_file_is_a_test_for_what_it_stands_for(tmp: string)
  local defs = file(tmp, "defs.tl", table.concat({
    "local record Defs",
    "  type Name = string",
    "  type Count = integer",
    "  type Flag = boolean",
    "  type Action = function(): integer",
    "end",
    "return Defs",
    "",
  }, "\n"))
  local use = file(tmp, "use.tl", table.concat({
    "local Defs = require(\"defs\")",
    "local type Local = Defs.Count",
    "local function kind(v: any): string",
    "  if v is Defs.Name then return \"name\" end",
    "  if v is Defs.Count then return \"count\" end",
    "  if v is Local then return \"never\" end",
    "  if v is Defs.Flag then return \"flag\" end",
    "  if v is Defs.Action then return \"action\" end",
    "  return \"other\"",
    "end",
    "return kind",
    "",
  }, "\n"))
  for _, defs_first in ipairs({ true, false }) do
    local first, second = defs, use
    if not defs_first then
      first, second = use, defs
    end
    local ran = run({ "-o", tmp .. "/out", first, second })
    assert(ran.code == 0, ran.err)
    local kind = module_of_dir(tmp .. "/out", "use")
    assert(kind is Kinder, "not a function")
    assert(kind("a") == "name" and kind(3) == "count" and kind(3.5) == "other" and kind(true) == "flag", "values")
    assert(kind(function(): integer return 1 end) == "action" and kind({ 1 }) == "other" and kind(nil) == "other", "others")
  end
end

--- A test the Lua cannot tell is refused, not written as a test for a table: `v is Circle` of a record would be
--- true of every table. A collection and a function type, whose Lua test is the right one, are only reported.
local function test_an_is_test_of_a_record_or_an_interface_is_refused_not_written_as_a_table_test(tmp: string)
  local shapes = file(tmp, "shapes.tl", table.concat({
    "local record Shapes",
    "  record Circle",
    "    r: integer",
    "  end",
    "  interface Round",
    "    r: integer",
    "  end",
    "end",
    "return Shapes",
    "",
  }, "\n"))
  local local_record = file(tmp, "local.tl", "local record Circle\n  r: integer\nend\n" ..
      "local function f(v: any): boolean\n  return v is Circle\nend\nreturn f\n")
  local imported = file(tmp, "imported.tl", "local Shapes = require(\"shapes\")\n" ..
      "local function f(v: any): boolean\n  return v is Shapes.Round\nend\nreturn f\n")
  for _, path in ipairs({ local_record, imported }) do
    local ran = run({ "-o", tmp .. "/out", shapes, path })
    assert(ran.code == 2, ran.err)
    assert(ran.err:find("the generator wrote no Lua", 1, true) and ran.err:find("(is_on_record)", 1, true), ran.err)
    assert(Fs.exists(tmp .. "/out/" .. (path:match("([^/]*)%.tl$") or "") .. ".lua") == false)
  end
  local tags = file(tmp, "tags.tl", "local function f(v: any): boolean\n  return v is {string: any} or v is function(): integer\nend\nreturn f\n")
  local ran = run({ "--errors", "-o", tmp .. "/ok", tags })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("(is_on_record)", 1, true), ran.err)
  local code = (assert(Fs.read(tmp .. "/ok/tags.lua")))
  assert(code:find('type(v) == "table"', 1, true) and code:find('type(v) == "function"', 1, true), code)
end

--- A class of another file cannot be tested here: its table is that file's local.
local function test_an_is_test_of_a_class_of_another_file_is_refused(tmp: string)
  local zoo = file(tmp, "zoo.tl", "local class Cat\n  lives: integer\nend\nreturn Cat\n")
  local user = file(tmp, "user.tl", "local Cat = require(\"zoo\")\nlocal function f(v: any): boolean\n  return v is Cat\nend\nreturn f\n")
  local ran = run({ "-o", tmp .. "/out", zoo, user })
  assert(ran.code == 2, ran.err)
  assert(ran.err:find("whose table this module cannot reach", 1, true), ran.err)
end

--- An enum of another file is a test for its values, as a local one is.
local function test_an_is_test_of_an_enum_of_another_file_tests_its_values(tmp: string)
  local defs = file(tmp, "colors.tl", "local record Colors\n  enum Color\n    \"red\"\n    \"green\"\n  end\nend\nreturn Colors\n")
  local user = file(tmp, "user.tl", "local Colors = require(\"colors\")\nlocal function f(v: string): boolean\n  return v is Colors.Color\nend\nreturn f\n")
  local ran = run({ "-o", tmp .. "/out", defs, user })
  assert(ran.code == 0, ran.err)
  local test = module_of_dir(tmp .. "/out", "user")
  assert(test is IsColor, "not a function")
  assert(test("red") == true and test("blue") == false)
end

--- A build over `text`, the module `m`.
local function built(text: string): Driver.Build
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index({ { "m.tl", text }, { "d.d.tl", "local record D\n  n: integer\nend\nreturn D\n" } },
    function(_file: string): boolean
      return false
    end)))
  return build
end

local function test_emit_writes_the_lua_of_a_module_checked_with_its_bodies_and_a_declaration_has_none()
  local build = built("local record R\n  n: integer\nend\nlocal r: R = { n = 1 }\nreturn r\n")
  local emitted = Grammar.emit(build, assert(build:result("m", true)))
  local code = emitted.code
  assert(code ~= nil and emitted.trouble == "" and type(value_of(code)) == "table")
  -- with no narrowed read the wraps add nothing
  assert(Grammar.emit(build, assert(build:result("m", true)), true).code == code)
  local none = Grammar.emit(build, assert(build:result("d", true)))
  assert(none.code == nil and none.trouble == "")
  -- a module whose bodies were not checked has none either
  local unchecked = built("return 1\n")
  assert(Grammar.emit(unchecked, assert(unchecked:result("m", false))).code == nil)
end

-- A file writes an `if` expression only for a middle value that is never false. The generator is told so for every source, or
-- it writes a function called on the spot where a file writes `and` and `or`.
local function test_emit_tells_the_generator_what_is_never_false_of_an_if_expression()
  local text = "local n = 3\nlocal s: string = if n > 2 then \"v\" else \"z\" end\nreturn s\n"
  local plain = built(text)
  local written = assert(Grammar.emit(plain, assert(plain:result("m", true))).code)
  assert(written:find("function", 1, true) == nil, written)
  assert(value_of(written) == "v")
end
