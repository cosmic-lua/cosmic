--- `cosmic compile` run as this program: its exit status, the absence of
--- a summary, a `require` between the files named, and its help.
--- The Lua and the refusals themselves are in `compile_test.tl`.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A module with a number in it, and the one global a `require` needs: a program has no globals but the ones a `.d.tl`
--- file named declares.
local LIB <const> = "local record lib\n  n: integer\nend\nlocal l: lib = { n = 1 }\nreturn l\n"
local REQUIRE <const> = "--- @kind binding\nglobal require: function(string): any\n"

local function test_it_prints_the_lua_and_no_summary(tmp: string)
  assert(Fs.write(tmp .. "/n.tl", "local n: integer = 7\nreturn n\n"))
  local ran = tool_fixture.cosmic(tmp, { "compile", "n.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("return n", 1, true), ran.out)
  assert(ran.err == "", ran.err)
end

local function test_a_syntax_error_exits_2_naming_file_and_line(tmp: string)
  assert(Fs.write(tmp .. "/bad.tl", "local a = 1\nlocal = 2\n"))
  local ran = tool_fixture.cosmic(tmp, { "compile", "bad.tl" })
  assert(ran.code == 2, ran.code)
  assert(ran.out == "" and ran.err:find("bad.tl:2:", 1, true) ~= nil, ran.err)
  assert(not ran.err:find("compile: FAIL", 1, true), ran.err)
end

--- A file named on the command line is the module its path names, so a
--- `require` of another is typed from that file: a wrong use is a type
--- error about its type, not a module that is not found.
local function test_a_require_of_a_named_file_is_typed_from_it(tmp: string)
  assert(Fs.write(tmp .. "/lib.tl", LIB))
  assert(Fs.write(tmp .. "/main.tl", "local lib = require(\"lib\")\nlocal s: string = lib.n\nreturn s\n"))
  assert(Fs.write(tmp .. "/globals.d.tl", REQUIRE))
  local ran = tool_fixture.cosmic(tmp, { "compile", "--errors", "-o", "out", "globals.d.tl", "lib.tl", "main.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("main.tl:2:", 1, true) and not ran.err:find("not found", 1, true), ran.err)
  assert(Fs.exists(tmp .. "/out/lib.lua") == true and Fs.exists(tmp .. "/out/main.lua") == true)
end

--- The library's own advice rides on the refusals of [`Json.Value`], which is named as a user writes it.
local function test_json_value_refusals_carry_the_librarys_advice(tmp: string)
  assert(Fs.write(tmp .. "/a.tl", "local Json = require(\"cosmic.json\")\nlocal a = Json.encode({})\n" ..
      "local b = Json.encode({ f = print })\nreturn { a, b }\n"))
  local ran = tool_fixture.cosmic(tmp, { "compile", "--errors", "a.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("write an empty array as `Json.array()`", 1, true), ran.err)
  assert(ran.err:find("`Json.Value` is `", 1, true) and ran.err:find("for a record or a class of your own, call `Json.encode_any`", 1, true), ran.err)
  assert(not ran.err:find("json.Value", 1, true), ran.err)
end

--- The refusals about a decoded value's collections name [`Json.Value`], never the core's own spelling.
local function test_refusals_about_decoded_collections_name_json_value(tmp: string)
  assert(Fs.write(tmp .. "/c.tl", "local Json = require(\"cosmic.json\")\n" ..
      "local function fill(m: mut {string: Json.Value}) m[\"x\"] = 1 end\n" ..
      "local obj = assert(Json.decode_object(\"{}\"))\nfill(obj)\n" ..
      "local items: mut {Json.Value} = {}\nlocal narrow: mut {string | number} = items\nreturn narrow\n"))
  local ran = tool_fixture.cosmic(tmp, { "compile", "--errors", "c.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("(view_as_mut)", 1, true) and ran.err:find("(invariant_mut)", 1, true), ran.err)
  assert(ran.err:find("Json.Value", 1, true) and not ran.err:find("json.Value", 1, true), ran.err)
end

--- A user's own record called `json` is untouched: its types keep their names.
local function test_a_users_json_record_keeps_its_names(tmp: string)
  assert(Fs.write(tmp .. "/d.tl", "local record json\n  record Config\n    name: string\n  end\n  enum Mode \"a\" \"b\" end\nend\n" ..
      "local c: json.Config = { name = 1 }\nlocal m: json.Mode = \"z\"\nreturn { c, m }\n"))
  local ran = tool_fixture.cosmic(tmp, { "compile", "--errors", "d.tl" })
  assert(ran.code == 0, ran.err)
  assert(ran.err:find("`json.Config`", 1, true) and ran.err:find("`json.Mode`", 1, true), ran.err)
  assert(not ran.err:find("Json.", 1, true), ran.err)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = tool_fixture.cosmic(tmp, { "compile", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic compile", 1, true) and ran.out:find("--errors", 1, true), ran.out)
end

--- A run from another directory with `--root` gives what a run at the root does.
local function test_a_run_from_another_directory_with_root_gives_the_same(tmp: string)
  assert(Fs.write(tmp .. "/lib.tl", LIB))
  assert(Fs.write(tmp .. "/main.tl", "local lib = require(\"lib\")\nlocal s: string = lib.n\nreturn s\n"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(Fs.write(tmp .. "/globals.d.tl", REQUIRE))
  local here = tool_fixture.cosmic(tmp, { "compile", "-o", "out", "globals.d.tl", "lib.tl", "main.tl" })
  local there = tool_fixture.cosmic(tmp .. "/elsewhere", { "compile", "--root", "..", "-o", "../out2", "../globals.d.tl", "../lib.tl",
    "../main.tl" })
  assert(here.code == 0 and there.code == 0, here.err .. there.err)
  assert(here.err:find("1 type error", 1, true) and there.err:find("1 type error", 1, true), there.err)
  assert(Fs.read(tmp .. "/out/main.lua") == Fs.read(tmp .. "/out2/main.lua"))
  local without = tool_fixture.cosmic(tmp .. "/elsewhere", { "compile", "-o", "o3", "../lib.tl" })
  assert(without.code == 2 and without.err:find("pass --root", 1, true) ~= nil, without.err)
end

--- The grammar is the new one, by default and by name; the fork's, which `--grammar teal` names, is refused, naming
--- the verb that rewrites a project to the new one.
local function test_the_grammar_flag_reads_the_new_grammar(tmp: string)
  assert(Fs.write(tmp .. "/n.tl", "for i = 1, 2 do\n  if i == 1 then continue end\nend\nlocal n = 7\n"))
  local new = tool_fixture.cosmic(tmp, { "compile", "--grammar", "new", "n.tl" })
  assert(new.code == 0, new.err)
  assert(new.out:find("goto continue", 1, true) and new.out:find("local n = 7", 1, true), new.out)
  local default = tool_fixture.cosmic(tmp, { "compile", "n.tl" })
  assert(default.code == 0 and default.out == new.out, default.err)
  local teal = tool_fixture.cosmic(tmp, { "compile", "--grammar", "teal", "n.tl" })
  assert(teal.code == 2 and teal.out == "", teal.err)
  assert(teal.err:find("--grammar teal: the fork's grammar is gone; rewrite a project to the new grammar by hand, as doc/guides/project.md says",
    1, true) ~= nil, teal.err)
end
