--- The layout of a file, or a refusal ([`build.fix.format`]). A file that does not parse is refused in the parser's
--- words. A layout that is not the same as the file, or not a fixed point, is never returned: `format` is given
--- layouts that are spoiled, which no source reaches through [`build.fix.layout`], and held to refuse them.
local Ast = require("lang.ast")
local Format = require("build.fix.format")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "build/fix/equiv.tl", letters = "r" }, { path = "build/fix/format.tl", letters = "r" },
    { path = "build/fix/trivia.tl", letters = "r" }, { path = "lang/ast_dump.tl", letters = "r" },
    { path = "cosmic/internal/json.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
  },
}

--- Asserts that `source` is laid out as `want`.
local function lays(source: string, want: string, name?: string)
  local got = Format.format(source, name or "f.tl")
  assert(got.text == want, string.format("%q\n got %q\nwant %q (%s)", source, tostring(got.text), want, got.why))
  assert(got.why == "" and got.kind == nil)
end

--- The refusal of `source`: its kind and why.
local function refused(source: string, name?: string): Format.Kind, string
  local got = Format.format(source, name or "f.tl")
  assert(got.text == nil, string.format("%q was laid out as %q", source, tostring(got.text)))
  local kind = got.kind
  assert(kind ~= nil)
  return kind, got.why
end

local function test_a_source_is_laid_out()
  lays("local x=1\n", "local x = 1\n")
  lays("if a then\n      b()\n  end", "if a then\n  b()\nend\n")
  lays("local t = {\n  1,\n  2\n}\n", "local t = {\n  1,\n  2,\n}\n")
  lays("a = 1 b = 2\n", "a = 1\nb = 2\n")
  lays("", "")
  lays("-- c\n", "-- c\n")
end

local function test_what_is_laid_out_is_laid_out_as_itself()
  local source = "local function f(a: integer): integer\n  -- c\n  return a +\n    1\nend\n"
  lays(source, source)
  local first = Format.format("local   t={1,2 ,}\n", "f.tl").text
  assert(first == "local t = { 1, 2 }\n", tostring(first))
  lays(first or "", first or "")
end

local function test_a_source_with_an_error_is_refused_in_the_parsers_words()
  local kind, why = refused("local x = = 1\n", "dir/f.tl")
  assert(kind == "syntax")
  assert(why:find("^dir/f%.tl:1:11: ") ~= nil, why)
  local other, trouble = refused("x = 1\nif then\n")
  assert(other == "syntax" and trouble:find("^f%.tl:2:") ~= nil, trouble)
  local lexical, said = refused("x = 'a\n")
  assert(lexical == "syntax" and said:find("^f%.tl:1:", 1) ~= nil, said)
end

local function test_a_declaration_file_is_read_as_one_and_any_other_name_as_a_program()
  -- A declaration has no body to end where the program's has: `end` is a syntax error in a declaration file, and the
  -- statements of a program are none.
  local source = "local record R\nend\nx = 1\n"
  assert(Format.format(source, "a.tl").text == source)
  assert(Format.format(source, "a.d.tl").kind == "syntax")
  assert(Format.format(source, "d.tl").text == source and Format.format(source, "a.d.tl.tl").text == source)
  -- The body of a record or an enum is the author's, aligned as the standard library's `OpenMode` is.
  lays("local  record R\n  x:integer\nend\n", "local record R\n  x:integer\nend\n", "a.d.tl")
  local grid = 'global enum OpenMode\n   "r"   "w"\n  "rb"  "wb"\nend\n'
  lays(grid, grid, "a.d.tl")
  local program = grid:gsub("global", "local")
  lays(program, program)
  lays("global record R\n  __call: function(R, ...: any): any...\nend\n", "global record R\n  __call: function(R, ...: any): any...\nend\n",
    "a.d.tl")
end

--- A layout that is `laid`, whatever the source.
local function giving(laid: string): Format.Layouter
  return function(_source: string, _name: string, _dialect?: Ast.Dialect): string?, string
    return laid, ""
  end
end

local function test_a_layout_that_is_not_the_same_as_the_file_is_refused()
  -- Spoiled the ways a faulty layout might: a token lost, one changed, a comment lost or moved, the tree changed.
  local source = "local x = 1 -- c\nlocal y = { 1, 2 }\n"
  for _, spoilt in ipairs({
      "local x = 1 -- c\nlocal y = { 1 }\n", "local x = 2 -- c\nlocal y = { 1, 2 }\n",
      "local x = 1\nlocal y = { 1, 2 }\n", "local x = 1\nlocal y = { 1, 2 } -- c\n",
      "local x = 1 -- c\nlocal y = { 1, 2 } local\n", "local x = 1 -- d\nlocal y = { 1, 2 }\n",
  }) do
    local got = Format.format(source, "f.tl", giving(spoilt))
    assert(got.text == nil and got.kind == "equivalence", string.format("%q: %s", spoilt, tostring(got.kind)))
    assert(got.why:find("f.tl: the layout is not the same as the file: ", 1, true) == 1, got.why)
  end
  -- The comma a table ends with is the layout's to add.
  local table_source = "local y = {\n  1,\n  2\n}\n"
  assert(Format.format(table_source, "f.tl", giving("local y = {\n  1,\n  2,\n}\n")).text ~= nil)
end

local function test_a_layout_that_loses_a_comment_at_the_end_of_the_file_is_refused()
  for _, source in ipairs({ "local x = 1\n-- last\n", "-- only\n", "local x = 1\n-- a\n-- b\n" }) do
    local got = Format.format(source, "f.tl", giving((source:gsub("%-%-[^\n]*\n$", ""))))
    assert(got.text == nil and got.kind == "equivalence", string.format("%q: %s", source, tostring(got.kind)))
    assert(got.why:find("was lost", 1, true) ~= nil, got.why)
  end
  local kept = "local x = 1\n-- last\n"
  assert(Format.format(kept, "f.tl").text == kept)
end

local function test_a_layout_that_is_not_a_fixed_point_is_refused()
  local got = Format.format("local x=1\n", "f.tl", giving("local x  =  1\n"))
  assert(got.text == nil and got.kind == "unstable", tostring(got.kind))
  assert(got.why:find("not a fixed point", 1, true) ~= nil, got.why)
  assert(Format.format("local x=1\n", "f.tl", giving("local x = 1\n")).text == "local x = 1\n")
  -- A comma the layout would drop is not at a fixed point either.
  local table_source = "local y = {\n  1,\n  2\n}\n"
  assert(Format.format(table_source, "f.tl", giving(table_source)).kind == "unstable")
end

--- Files of the tree, programs and declaration files, which `format` lays out without a refusal.
local FILES <const>: {string} = {
  "build/fix/equiv.tl", "build/fix/format.tl", "build/fix/trivia.tl", "lang/ast_dump.tl", "cosmic/internal/json.d.tl",
  "lang/prelude.d.tl",
}

local function test_files_of_the_tree_are_laid_out_not_refused_and_a_second_layout_changes_nothing()
  for _, path in ipairs(FILES) do
    local source = assert(Fs.read(path))
    local got = Format.format(source, path)
    local text = got.text
    assert(text ~= nil, string.format("%s was refused: %s", path, got.why))
    assert(Format.format(text, path).text == text, path .. " is not a fixed point")
  end
end
