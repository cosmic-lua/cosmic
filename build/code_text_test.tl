--- Tests of [`build.code_text`]: what an identity of code hashes in place of a source.

local code_text = require("build.code_text")

local function same(a: string, b: string): boolean
  return code_text.of(a, "a.tl") == code_text.of(b, "b.tl")
end

--- Comments and layout are no code; a token's bytes are, a string's and a long string's among them.
local function test_comments_and_layout_leave_the_code_text_alone()
  local base = "local x = 1\nreturn x\n"
  assert(same(base, "-- a comment\nlocal   x =\t1 -- why\n\n\nreturn x"), "a comment or layout moved the code text")
  assert(same(base, "--- A doc block.\n--- @public\nlocal x = 1\nreturn x -- checked: any_use\n"), "a doc block moved it")
  assert(not same(base, "local x = 2\nreturn x\n"), "a number edited left the code text alone")
  assert(not same(base, "local y = 1\nreturn y\n"), "a name edited left it alone")
  -- What looks like a comment in a string is the string's.
  assert(not same('local s = "a -- b"\nreturn s\n', 'local s = "a "\nreturn s\n'), "a string's -- was read as a comment")
  assert(not same('local s = [[\n-- kept\n]]\nreturn s\n', 'local s = [[\n]]\nreturn s\n'), "a long string's line was dropped")
  assert(not same('local s = "a b"\nreturn s\n', 'local s = "a  b"\nreturn s\n'), "a string's spaces were taken for layout")
  -- Tokens that run together are not two that stand apart.
  assert(not same("return a.b\n", "return a .. b\n"), "two tokens were joined")
end

--- A source the lexer finds an error in is its own code text, so no edit to it is taken for none.
local function test_a_source_the_lexer_refuses_is_its_whole_text()
  local broken = 'local s = "unterminated\nreturn s\n'
  assert(code_text.of(broken, "a.tl") == "source\n" .. broken)
  assert(not same(broken, broken .. "-- a comment\n"), "a comment on a source that does not lex moved nothing")
  assert(code_text.of("return 1\n", "a.tl"):sub(1, 5) == "code\n")
end

--- A token that begins a line is not one that goes on the line before it: the parser reads the break
--- (`local x = f()` then `(g)()` is two statements, on one line a call of a call).
local function test_a_line_joined_moves_the_code_text()
  assert(not same("local x = f()\n(g)()\n", "local x = f()(g)()\n"), "a line joined left the code text alone")
  assert(same("local x = f()\n(g)()\n", "local x = f() -- a call\n\n  (g)() -- and another\n"),
    "a comment or a blank line between two lines moved the code text")
  assert(not same("local s = [[a\nb]] x()\n", "local s = [[a\nb]]\nx()\n"),
    "a token on the line a long string ends was taken for one that begins a line")
end
