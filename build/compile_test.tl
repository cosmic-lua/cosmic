--- `cosmic compile` (build/compile.tl), run in this process: a type error is reported and its Lua written anyway, a syntax
--- error is refused naming file and line and writes nothing, a well-typed file's Lua is what the generator writes, and each
--- file of several gets its own output. build/compile_tool_test.tl starts the program for what a process alone shows, and
--- build/compile_grammar_test.tl holds the pipeline it runs.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local compile = require("build.compile")
local Grammar = require("build.compile_grammar")

-- With no declaration file named the files are typed against the declarations the tool carries, which only a worker that holds
-- the tool's database ("cosmic") has.
Test.policy{ profiles = { "cosmic" } }

local record Ran
  mut code: integer
  mut out: string
  mut err: string
end

--- The directory of the test's files, which a run takes as `--root`
--- unless it names another: the working directory is not the test's.
local where: mut {string} = {}

--- One run: `words` after `cosmic compile`, its output collected.
local function run(words: {string}): Ran
  local argv: mut {string} = { "compile" }
  local rooted = false
  for _, word in ipairs(words) do rooted = rooted or word == "--root" end
  if not rooted then
    argv[#argv + 1] = "--root"
    argv[#argv + 1] = where[1]
  end
  for _, word in ipairs(words) do argv[#argv + 1] = word end
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
  assert(Fs.write(path, text))
  return path
end

--- What the generator writes for `text`, compiled alone as `compile` compiles a file named on its command line.
local function generated(text: string): string
  local made = Grammar.compile({ { path = "x.tl", relative = "x.tl", text = text, declaration = false } })
  local code = assert(made[1]).code
  assert(code ~= nil and #assert(made[1]).syntax_errors == 0)
  return code
end

local function test_a_type_error_is_reported_and_the_lua_is_written_anyway(tmp: string)
  local path = file(tmp, "typed.tl", "local n: number = \"text\"\nreturn n\n")
  local ran = run({ "--errors", path })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("return n", 1, true), ran.out)
  assert(ran.err:find("typed.tl:1:", 1, true), ran.err)
  assert(ran.err:find("1 type error", 1, true) and ran.err:find("written anyway", 1, true), ran.err)
  assert(load(ran.out, "=typed") ~= nil, "the Lua written does not load")
  assert(ran.out == generated("local n: number = \"text\"\nreturn n\n"))
end

local function test_the_count_alone_is_reported_without_errors(tmp: string)
  local path = file(tmp, "typed.tl", "local n: number = \"text\"\nreturn n\n")
  local ran = run({ path })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("1 type error", 1, true) and ran.err:find("--errors", 1, true), ran.err)
  assert(not ran.err:find("typed.tl:1:", 1, true), ran.err)
end

local function test_a_syntax_error_is_refused_naming_the_file_and_line(tmp: string)
  local path = file(tmp, "broken.tl", "local a = 1\nlocal b = = 2\nreturn a\n")
  local ran = run({ path })
  assert(ran.code == 2, ran.code)
  assert(ran.out == "", ran.out)
  assert(ran.err:find("broken.tl:2:", 1, true), ran.err)
  assert(ran.err:find("syntax error", 1, true) and ran.err:find("fix the line", 1, true), ran.err)
end

local function test_a_syntax_error_writes_no_file_at_all(tmp: string)
  local good = file(tmp, "good.tl", "return 1\n")
  local bad = file(tmp, "bad.tl", "return (\n")
  local ran = run({ "-o", tmp .. "/out", good, bad })
  assert(ran.code == 2, ran.code)
  assert(ran.err:find("bad.tl:", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/good.lua") == false, "good.lua was written beside a refused file")
  assert(Fs.exists(tmp .. "/out/bad.lua") == false)
end

local function test_a_well_typed_file_gives_the_lua_the_compiler_writes(tmp: string)
  local text = "local record Point\n  x: integer\n  y: integer\nend\n" ..
    "local function sum(p: Point): integer\n  return p.x + p.y\nend\n" ..
    "local total: integer = sum({ x = 1, y = 2 })\nreturn total\n"
  local ran = run({ file(tmp, "point.tl", text) })
  assert(ran.code == 0, ran.err)
  assert(ran.err == "", ran.err)
  assert(ran.out == generated(text), ran.out)
  local chunk = assert(load(ran.out, "=point"))
  assert(chunk() == 3)
end

local function test_several_files_give_one_output_each_raw(tmp: string)
  local a = file(tmp, "a.tl", "return \"a\"\n")
  local b = file(tmp, "b.tl", "local n: integer = 1\nreturn n\n")
  local ran = run({ "-o", tmp .. "/deep/out", a, b })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(tmp .. "/deep/out/a.lua") == generated("return \"a\"\n"))
  assert(Fs.read(tmp .. "/deep/out/b.lua") == generated("local n: integer = 1\nreturn n\n"))
  local names = assert(Fs.list(tmp .. "/deep/out"))
  assert(#names == 2, table.concat(names, ","))
end

--- Each refusal of the command line says how to fix it.
local function test_a_command_line_it_refuses_says_how_to_fix_it(tmp: string)
  local one = file(tmp, "one.tl", "return 1\n")
  local two = file(tmp, "two.tl", "return 2\n")
  local decl = file(tmp, "types.d.tl", "return {}\n")
  local function refused(words: {string}, fix: string)
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", tostring(ran.code) .. ran.out)
    assert(ran.err:find(fix, 1, true), "wanted " .. fix .. " in " .. ran.err)
    assert(ran.err:find("cosmic: compile: ", 1, true), ran.err)
  end
  refused({}, "name at least one .tl file")
  refused({ one, two }, "give -o <dir>")
  refused({ tmp .. "/missing.tl" }, "check the path")
  refused({ decl }, "every file named is a .d.tl")
  local pair = file(tmp, "one.d.tl", "local record One\nend\nreturn One\n")
  refused({ "-o", tmp .. "/o", one, pair }, pair .. ": " .. one .. " is also the module one, and a module has one type source")
  refused({ "-o", tmp .. "/o", pair, one }, "Delete " .. pair)
  local named: {{string}} = { { "math.tl", "math" }, { "string.d.tl", "string" }, { "table.tl", "table" } }
  for _, pair in ipairs(named) do
    local name, module = assert(pair[1]), assert(pair[2])
    local language = file(tmp, name, "return {}\n")
    refused({ "-o", tmp .. "/o", one, language }, name .. ": its module is named for `" .. module ..
        "`, which the binary answers at run time with the language's own module")
  end
  local near = file(tmp, "mathlib.tl", "local n: integer = 1\nreturn n\n")
  assert(run({ "-o", tmp .. "/near", near }).code == 0)
  refused({ one, "--root", tmp .. "/nowhere" }, "--root must name a directory")
  refused({ tmp .. "/readme.md" }, "not a .tl source")
  refused({ "-o", tmp .. "/o", one, tmp .. "/./one.tl" }, "named twice: name it once")
  refused({ "--root", one, one }, "--root must name a directory")
  refused({ "--nosuch", one }, "--nosuch")
end

--- The one global the cases below use: a program has no globals but the ones a `.d.tl` file given declares.
local REQUIRE <const> = "global require: function(string): any\n"

local function test_a_d_tl_is_skipped_with_a_note_and_types_a_require(tmp: string)
  local globals = file(tmp, "globals.d.tl", REQUIRE)
  local decl = file(tmp, "shapes.d.tl", "local record Shape\n  n: integer\nend\nreturn Shape\n")
  local user = file(tmp, "user.tl", "local Shape = require(\"shapes\")\nlocal s: Shape = { n = 1 }\nreturn s\n")
  local ran = run({ "--errors", "-o", tmp .. "/out", globals, decl, user })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("shapes.d.tl: declares globals and types and has no Lua", 1, true), ran.err)
  assert(not ran.err:find("not found", 1, true) and not ran.err:find("type error", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/user.lua") == true and Fs.exists(tmp .. "/out/shapes.lua") == false)
end

--- Names are relative to the root, however a path is spelt.
local function test_a_path_is_taken_below_the_root_however_it_is_spelt(tmp: string)
  local globals = file(tmp, "globals.d.tl", REQUIRE)
  local lib = file(tmp, "lib.tl", "local record lib\n  n: integer\nend\nlocal l: lib = { n = 1 }\nreturn l\n")
  local main = file(tmp, "main.tl", "local lib = require(\"lib\")\nlocal s: string = lib.n\nreturn s\n")
  assert(Fs.mkdirs(tmp .. "/sub"))
  local plain = run({ "--errors", "-o", tmp .. "/one", globals, lib, main })
  local spelt = run({ "--errors", "-o", tmp .. "/two", tmp .. "/./globals.d.tl", tmp .. "/./lib.tl",
    tmp .. "/sub/../main.tl" })
  assert(plain.code == 0 and spelt.code == 0, plain.err .. spelt.err)
  assert(plain.err:find("main.tl:2:", 1, true) and not plain.err:find("not found", 1, true), plain.err)
  assert(spelt.err:find("1 type error", 1, true) and not spelt.err:find("not found", 1, true), spelt.err)
  assert(Fs.read(tmp .. "/one/main.lua") == Fs.read(tmp .. "/two/main.lua"))
end

local function test_a_path_outside_the_root_is_refused_saying_to_pass_root(tmp: string)
  local path = file(tmp, "x.tl", "return 1\n")
  assert(Fs.mkdirs(tmp .. "/sub"))
  local ran = run({ "--root", tmp .. "/sub", path })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("pass --root", 1, true), ran.err)
end

local function test_dots_and_dot_segments_in_a_name_are_not_a_problem(tmp: string)
  local dotted = file(tmp, "a..b.tl", "return 5\n")
  local ran = run({ tmp .. "/./a..b.tl" })
  assert(ran.code == 0 and ran.out == generated("return 5\n"), ran.err)
  assert(dotted ~= "")
end

local function test_a_require_nothing_names_says_how_to_fix_it(tmp: string)
  local main = file(tmp, "main.tl", "local lib = require(\"lib\")\nreturn lib\n")
  local ran = run({ "--errors", main })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("--root", 1, true) and ran.err:find("pass that file", 1, true), ran.err)
end

local function test_a_directory_that_is_a_file_is_named_once(tmp: string)
  local one = file(tmp, "one.tl", "local n: integer = 1\nreturn n\n")
  local ran = run({ "-o", one, one })
  assert(ran.code == 2, ran.code)
  local first = ran.err:find(one, 1, true)
  assert(first ~= nil and ran.err:find(one, first + 1, true) == nil, ran.err)
end

local function test_two_files_of_one_name_or_module_are_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/x"))
  assert(Fs.mkdirs(tmp .. "/other/x"))
  local nested = file(tmp, "x/y.tl", "return 1\n")
  local dotted = file(tmp, "x.y.tl", "return 2\n")
  local same = file(tmp, "other/x/y.tl", "return 3\n")
  local module = run({ "-o", tmp .. "/o", nested, dotted })
  assert(module.code == 2 and module.err:find("both the module x.y", 1, true) ~= nil, module.err)
  local base = run({ "-o", tmp .. "/o", nested, same })
  assert(base.code == 2 and base.err:find("compile them in two runs", 1, true) ~= nil, base.err)
  assert(Fs.exists(tmp .. "/o/y.lua") == false)
end

--- A declaration types a require of it whichever file is named first.
local function test_a_declaration_types_a_require_in_any_order(tmp: string)
  local decl = file(tmp, "foo.d.tl", "local record Foo\n  n: integer\nend\nreturn Foo\n")
  local user = file(tmp, "user.tl",
    "local type Foo = require(\"foo\")\nlocal f: Foo = { n = \"text\" }\nreturn f\n")
  for _, order in ipairs({ { decl, user }, { user, decl } }) do
    local words: mut {string} = { "--errors", "-o", tmp .. "/out" }
    for _, path in ipairs(order) do words[#words + 1] = path end
    local ran = run(words)
    assert(ran.code == 0, ran.err)
    assert(ran.err:find("user.tl:2:", 1, true), ran.err)
  end
end

local function test_a_dotted_directory_is_a_path_not_a_module_path(tmp: string)
  assert(Fs.mkdirs(tmp .. "/v1.2"))
  local path = file(tmp, "v1.2/m.tl", "local n: number = \"text\"\nreturn n\n")
  local ran = run({ "--errors", path })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("v1.2/m.tl:1:", 1, true) and not ran.err:find("v1/2", 1, true), ran.err)
end

--- A standalone script, as `cosmic --standalone` types it: the prelude's globals and the `cosmic.*` modules are known, and the
--- one real mistake and the unused local that `--standalone` refuses are all `--errors` names.
local function test_a_file_with_no_declaration_is_checked_as_standalone_checks_it(tmp: string)
  local text = [[
local Sqlite = require("cosmic.sqlite")
local Proc = require("cosmic.proc")
local broken: integer = "definitely a string"
assert(type(Sqlite) == "table" and type(Proc) == "table")
for i, v in ipairs({ "a" }) do
  print(tostring(i) .. string.upper(v) .. table.concat({ "b" }))
end
]]
  local path = file(tmp, "broken.tl", text)
  local ran = run({ "--errors", path })
  assert(ran.code == 0, ran.err)
  assert(not ran.err:find("unknown_variable", 1, true), ran.err)
  assert(not ran.err:find("unchecked_binding", 1, true), ran.err)
  assert(ran.err:find("not_assignable", 1, true), ran.err)
  assert(ran.err:find("unused_variable", 1, true), ran.err)
  assert(ran.err:find("2 type errors", 1, true), ran.err)
  assert(load(ran.out, "=broken") ~= nil, "the Lua written does not load")
end

--- A clean script has nothing to list.
local function test_a_clean_standalone_script_lists_no_errors(tmp: string)
  local path = file(tmp, "clean.tl", "local Fs = require(\"cosmic.fs\")\nreturn function(): integer\n  return Fs.stdout\nend\n")
  local ran = run({ "--errors", path })
  assert(ran.code == 0 and ran.err == "", ran.err)
end

--- What `--standalone` refuses of a project's program besides types (`package`, `_G`) is listed as `--standalone --check`
--- lists it, with the Lua still written.
local function test_a_file_alone_lists_the_refusals_standalone_makes_of_a_project(tmp: string)
  local package_at = file(tmp, "pkg.tl", "print(package.path)\n")
  local ran = run({ "--errors", package_at })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("pkg.tl:1:7:", 1, true) and ran.err:find("`package` holds the loaded modules", 1, true), ran.err)
  assert(ran.err:find("1 type error", 1, true), ran.err)
  assert(load(ran.out, "=pkg") ~= nil, "the Lua written does not load")
  local global_at = file(tmp, "glob.tl", "local x = _G\nprint(x)\n")
  local second = run({ "--errors", global_at })
  assert(second.code == 0, second.err)
  assert(second.err:find("glob.tl:1:11:", 1, true) and second.err:find("`_G` is the table of the globals", 1, true), second.err)
end
