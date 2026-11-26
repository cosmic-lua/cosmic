--- What of a source the checks of the files that require it read ([`build.shape_key`]): an edit to a comment or to the blank
--- lines between statements or inside a function's body leaves the digest alone, and any other change to what the lexer reads
--- moves it.
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
  assert(first ~= digest((base:gsub("\n  n: integer", " n: integer"))), "joining two lines was not seen")
  assert(first ~= digest((base:gsub("n: integer", "n:  integer"))), "a column was not seen")
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

local function test_an_edit_inside_a_function_body_does_not_move_the_digest()
  local first = digest(base)
  assert(first == digest((base:gsub("return x.n", "local m = x.n\n  return m"))), "a statement of a body moved it")
  local statics = "local record M\nend\n\nfunction M.f(x: integer): integer\n  return x + 1\nend\n\n" ..
    "M.g = function(s: string): string return s .. 'a' end\n\nreturn M\n"
  local held = digest(statics)
  assert(held == digest((statics:gsub("x %+ 1", "x * 2"))), "a static's body moved it")
  assert(held == digest((statics:gsub("'a'", "'b'"))), "a literal function's body moved it")
  local nested = "local function f(): integer\n  local function g(): integer return 1 end\n  return g()\nend\nreturn f\n"
  assert(digest(nested) == digest((nested:gsub("return 1", "return 2"))), "a function nested in a body moved it")
end

local function test_a_signature_or_a_statement_outside_a_body_moves_the_digest()
  local first = digest(base)
  assert(first ~= digest((base:gsub("%(x: R%): integer", "(x: R): number"))), "a return type was not seen")
  assert(first ~= digest((base:gsub("%(x: R%)", "(y: R)"))), "a parameter's name was not seen")
  local statics = "local record M\nend\n\nfunction M.f(x: integer): integer\n  return x\nend\n\nreturn M\n"
  assert(digest(statics) ~= digest((statics:gsub("M%.f", "M.h"))), "a static's name was not seen")
  assert(digest(statics) ~= digest((statics:gsub("return M\n$", "M.v = 1\nreturn M\n"))), "a top statement was not seen")
end

local function test_a_body_that_does_not_parse_is_held_by_every_token()
  -- Which tokens a body holds is not known where the parser refused the source.
  local broken = "local function f(): integer\n  return 1 +\nend\nreturn f\n"
  assert(digest(broken) ~= digest((broken:gsub("1 %+", "2 +"))), "a source that does not parse dropped a token")
end

local function test_a_require_inside_a_body_or_an_empty_body_is_held()
  local plain = "local function f(): integer\n  return 1\nend\nreturn f\n"
  local requiring = "local function f(): integer\n  local _ = require(\"cosmic.fs\")\n  return 1\nend\nreturn f\n"
  assert(digest(plain) ~= digest(requiring), "a require inside a body was not seen")
  local empty = "local function f() end\nlocal x = 1\nreturn f\n"
  assert(digest(empty) ~= digest((empty:gsub("x = 1", "x = 2"))), "a statement after an empty body was not seen")
  assert(digest(empty) ~= digest((empty:gsub("end\nlocal", "end local"))), "a token joined to a body's end was not seen")
end
