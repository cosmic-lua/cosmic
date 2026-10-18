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
