--- The steps [`build.lang_proof`] applies to the translation of lang/: the `where` clauses blanked, and a test of
--- a record they told apart written as the tag test they were. Running the tests of lang/ against the Lua is the
--- program's own work (a process for each test module), done by hand and not here.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local LangProof = require("build.lang_proof")

Test.policy{ grants = { { path = "lang/", letters = "r" } } }

local AST_SOURCE <const> = table.concat({
  "local record Ast",
  "  record Local is Base",
  "    where self.kind == \"Local\"",
  "  end",
  "  record Name is Base",
  "    where self.kind == \"Name\"",
  "  end",
  "  record Plain",
  "  end",
  "  type Exp = Local |",
  "    Name",
  "end",
  "",
}, "\n")

local TYPES_SOURCE <const> = table.concat({
  "local record Types",
  "  record Atom is Base",
  "    where self.atom",
  "  end",
  "  record Named is Base",
  "    where self.tag == \"named\"",
  "  end",
  "end",
  "",
}, "\n")

local function test_where_clauses_are_blanked_and_the_lines_stay()
  local edited = LangProof.blank_where(AST_SOURCE)
  assert(edited.count == 2 and not edited.text:find("where", 1, true), edited.text)
  local _, lines = edited.text:gsub("\n", "\n")
  local _, was = AST_SOURCE:gsub("\n", "\n")
  assert(lines == was, "a line moved")
end

local function test_a_test_of_a_record_a_clause_told_apart_is_its_tag_test()
  local tags = LangProof.tags(AST_SOURCE, TYPES_SOURCE)
  local text = table.concat({
    "local Ast = require(\"lang.ast\")",
    "local Types = require(\"lang.types\")",
    "local type Named = Types.Named",
    "local function f(node: any, t: any, x: {any}): boolean",
    "  local a = node is Ast.Local",
    "  local b = not (t is Named) and t is Types.Atom",
    "  local c = x[1] is Ast.Exp",
    "  local d = node is Ast.Plain",
    "  return a",
    "end",
    "",
  }, "\n")
  local edited = LangProof.rewrite(text, "t.tl", tags)
  assert(edited.count == 4, edited.text)
  assert(edited.text:find("local a = (node.kind == \"Local\")", 1, true), edited.text)
  assert(edited.text:find("not ((t.tag == \"named\")) and (t.atom == true)", 1, true), edited.text)
  assert(edited.text:find("(function(v: any): boolean return v.kind == \"Local\" or v.kind == \"Name\" end)(x[1])", 1, true),
    edited.text)
  assert(edited.text:find("local d = node is Ast.Plain", 1, true), "a record with no clause is left")
end

--- The translation of two files of lang/ compiles in the new grammar to Lua, with no test of a record left.
local function test_a_part_of_lang_is_translated_and_compiled_with_the_new_grammar(tmp: string)
  local prepared = LangProof.prepare(".", tmp, { "lexer_test" })
  assert(#prepared.files == 4, table.concat(prepared.files, ","))
  assert(Fs.exists(tmp .. "/src/lang/lexer_test.tl") == true)
  assert((Fs.read(tmp .. "/src/lang/lexer_test.tl") or ""):find("\nreturn { test_", 1, true) ~= nil, "no exported tests")
  local built = LangProof.build(tmp, prepared.files)
  assert(built.code == 0, built.complaints)
  for _, stem in ipairs(prepared.files) do
    assert(Fs.exists(tmp .. "/lua/" .. stem .. ".lua") == true, stem .. " has no Lua")
  end
end

local function test_the_names_of_the_seed_differs_file_are_one_bare_name_a_line()
  assert(#LangProof.listed("") == 0 and #LangProof.listed("\n  \n") == 0)
  local names = LangProof.listed("codegen.lua\n  lexer.lua  \n\nparser.lua")
  assert(#names == 3 and names[1] == "codegen.lua" and names[2] == "lexer.lua" and names[3] == "parser.lua")
end

local function test_files_whose_lua_differs_are_named_in_the_order_given_and_a_missing_one_differs(tmp: string)
  for _, side in ipairs({ "a", "b" }) do
    assert(Fs.mkdirs(tmp .. "/" .. side))
  end
  assert(Fs.write(tmp .. "/a/one.lua", "return 1\n") and Fs.write(tmp .. "/b/one.lua", "return 1\n"))
  assert(Fs.write(tmp .. "/a/two.lua", "return 2\n") and Fs.write(tmp .. "/b/two.lua", "return 3\n"))
  assert(Fs.write(tmp .. "/a/three.lua", "return 4\n"))
  local differ = LangProof.differing({ "three", "one", "two", "four" }, tmp .. "/a", tmp .. "/b")
  assert(table.concat(differ, ",") == "three.lua,two.lua,four.lua", table.concat(differ, ","))
  assert(#LangProof.differing({}, tmp .. "/a", tmp .. "/b") == 0, "nothing built compares as equal")
end

local function test_the_seed_is_held_to_the_file_both_ways()
  local written = { "codegen", "lexer" }
  -- agreement, listed or not
  assert(#LangProof.judged({}, {}, written, false) == 0)
  assert(#LangProof.judged({ "codegen.lua" }, { "codegen.lua" }, written, true) == 0)
  -- a file that differs and is not listed
  local undeclared = LangProof.judged({ "codegen.lua", "lexer.lua" }, { "codegen.lua" }, written, true)
  assert(#undeclared == 1 and table.concat(undeclared):find("writes lexer.lua otherwise", 1, true) ~= nil, table.concat(undeclared, "\n"))
  -- a listed file that does not differ
  local stale = LangProof.judged({}, { "lexer.lua" }, written, true)
  assert(#stale == 1 and table.concat(stale):find("lists lexer.lua, which the seed writes as the tree's compile does", 1, true) ~= nil,
    table.concat(stale, "\n"))
  -- a name that is no file
  local unknown = LangProof.judged({}, { "nothing.lua" }, written, true)
  assert(#unknown == 1 and table.concat(unknown):find("nothing.lua names no file lang/ compiles to", 1, true) ~= nil, table.concat(unknown, "\n"))
  -- a file that is there and lists nothing
  local empty = LangProof.judged({}, {}, written, true)
  assert(#empty == 1 and table.concat(empty):find("lists no file: remove it", 1, true) ~= nil, table.concat(empty, "\n"))
end
