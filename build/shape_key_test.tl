--- What of a source the checks of the files that require it read ([`build.shape_key`]): an edit to a comment or to the blank
--- lines between statements leaves the digest alone, and any other change to what the lexer reads moves it.
local ShapeKey = require("build.shape_key")

local base = "local record R\n  n: integer\nend\n\nlocal function f(x: R): integer\n  return x.n\nend\n\nreturn f\n"

local function digest(text: string): string
  return ShapeKey.digest(text, "x.tl")
end

local function test_a_comment_or_blank_lines_do_not_move_the_digest()
  local first = digest(base)
  assert(first == digest(base))
  assert(first == digest("-- a comment\n" .. base), "a comment above moved it")
  assert(first == digest(base .. "-- at the end\n"), "a comment at the end moved it")
  assert(first == digest((base:gsub("end\n\n", "end\n-- between\n\n"))), "a comment between statements moved it")
  assert(first == digest((base:gsub("\n\n", "\n\n\n\n"))), "blank lines moved it")
  assert(first == digest((base:gsub("  n: integer\n", "  n: integer -- the count\n"))), "a comment after a token moved it")
  assert(first == digest((base:gsub("  n: integer\n", "  --- the count\n  n: integer\n"))), "a doc comment moved it")
end

local function test_any_other_change_moves_the_digest()
  local first = digest(base)
  assert(first ~= digest((base:gsub("integer", "number"))), "another type was not seen")
  assert(first ~= digest((base:gsub("  n: integer", "  m: integer"))), "another field was not seen")
  assert(first ~= digest((base:gsub("\n  return x.n", " return x.n"))), "joining two lines was not seen")
  assert(first ~= digest((base:gsub("return x.n", "return  x.n"))), "a column was not seen")
  assert(first ~= digest((base:gsub("  n: integer", "    n: integer"))), "an indent was not seen")
  assert(first ~= digest((base:gsub("local function", "local   function"))), "a column of a later token was not seen")
  assert(first ~= digest(base .. "local s = 'x'\n"), "a statement more was not seen")
  assert(digest("local s = 'a'\n") ~= digest("local s = \"a\"\n"), "a quote was not seen")
  assert(digest("local s = [[a]]\n") ~= digest("local s = [[b]]\n"), "a long string was not seen")
end

local function test_a_form_the_lexer_refuses_is_held_for_what_it_is()
  -- A long comment is a lexical error, which the digest holds by its code: one is not a line comment.
  assert(digest("--[[ one ]]\nlocal x = 1\n") ~= digest("-- one\nlocal x = 1\n"), "a long comment was a line comment")
  assert(digest("local x = 1;\n") ~= digest("local x = 1\n"), "a semicolon was not seen")
end
