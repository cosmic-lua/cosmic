--- What it takes for two sources to be the same ([`build.fix.equiv`]), and the changes a faulty layout could make
--- that it must find. A check that answered "same" to everything would turn off the guard of [`build.fix.format`]
--- without a trace, so each case here is a change a layout could plausibly make (a token dropped or altered, a
--- comment lost, moved across code or parted from its declaration, the tree changed) and each must be found. The
--- cases of whitespace and breaks go the other way: a layout changes those, and the check must not refuse it for that.
local Equiv = require("build.fix.equiv")
local Test = require("cosmic.test")

Test.policy{}

--- Why `after` differs from `before` (both parse), or nil.
local function difference(before: string, after: string): string?
  return Equiv.difference(Equiv.read(before, "a.tl", "tl"), Equiv.read(after, "b.tl", "tl"))
end

--- Asserts that `after` is the same as `before`.
local function same(before: string, after: string)
  local why = difference(before, after)
  assert(why == nil, string.format("%q and %q differ: %s", before, after, tostring(why)))
end

--- Asserts that `after` differs from `before`, and that the reason holds `fragment`.
local function differs(before: string, after: string, fragment: string)
  local why = difference(before, after)
  assert(why ~= nil, string.format("%q and %q were taken for the same", before, after))
  assert(why:find(fragment, 1, true) ~= nil, string.format("%q and %q differ, but not as %q: %s", before, after, fragment, why))
end

local function test_whitespace_breaks_and_blank_lines_are_no_difference()
  same("local x=1\n", "local x = 1\n")
  same("if a then\nb()\nend\n", "if a then b() end\n")
  same("a = 1\n\n\n\nb = 2", "a = 1\n\nb = 2\n")
  same("f(a,\n    b)\n", "f(a, b)\n")
  same("#!/bin/cosmic\nx = 1\n", "#!/bin/cosmic\n\nx = 1\n")
  same("", "\n")
end

local function test_the_comma_a_table_ends_with_is_no_difference_and_no_other_comma_is()
  same("local t = { 1, 2 }\n", "local t = {\n  1,\n  2,\n}\n")
  same("local t = { 1, 2, }\n", "local t = { 1, 2 }\n")
  same("local t = { a = { 1, }, b }\n", "local t = { a = { 1 }, b, }\n")
  differs("local t = { 1, 2 }\n", "local t = { 1 }\n", "the token at 1:14")
  differs("local t = { 1, 2 }\n", "local t = { 1, 2, 3 }\n", "token")
  -- A comma between two entries, or between two arguments, is not the one a table ends with.
  differs("f(a, b)\n", "f(a)\n", "the token at 1:4")
  differs("local t = { 1, 2 }\n", "local t = { 1, 3 }\n", "is")
  assert(difference("local t = { 1, 2 }\n", "local t = { 1 2 }\n") ~= nil)
end

local function test_a_token_added_lost_or_changed_is_a_difference()
  differs("local x = 1\n", "local x = 2\n", "\"1\"")
  differs("local x = a + b\n", "local x = a - b\n", "\"+\"")
  differs("local x <const> = 1\n", "local x = 1\n", "the token at 1:9")
  differs("local x = 1\n", "local x <const> = 1\n", "the token at 1:9")
  differs("local x <const> = 1\n", "local x <close> = 1\n", "\"const\"")
  differs("local s = 'a'\n", "local s = \"a\"\n", "'a'")
  differs("f(a)\n", "f(b)\n", "\"a\"")
  differs("local x = a\n", "local y = a\n", "\"x\"")
end

local function test_the_tree_changed_where_the_tokens_did_not_is_a_difference()
  -- A line break the grammar reads: a line that begins with `(` is a statement, and after a call on the line before
  -- it, joined to it, it would be a call of its result.
  differs("f(a)\n(b).c = 1\n", "f(a) (b).c = 1\n", "the syntax tree changed")
end

local function test_a_comment_added_lost_or_changed_is_a_difference()
  differs("-- c\nx = 1\n", "x = 1\n", "lost")
  differs("x = 1\n", "-- c\nx = 1\n", "added")
  differs("-- c\nx = 1\n", "-- d\nx = 1\n", "changed")
  differs("x = 1 -- c\n", "x = 1 -- c \n", "changed")
  differs("x = 1 -- c\ny = 2 -- d\n", "x = 1 -- d\ny = 2 -- c\n", "changed")
  differs("x = 1\n-- c\n", "-- c", "")
end

local function test_a_comment_moved_across_code_is_a_difference()
  differs("-- c\nx = 1\ny = 2\n", "x = 1\n-- c\ny = 2\n", "comes after")
  differs("x = 1 -- c\ny = 2\n", "x = 1\ny = 2 -- c\n", "comes after")
  differs("f(a, -- c\n  b)\n", "f(a,\n  b) -- c\n", "comes after")
end

--- A comment past the last token hangs on the end of the file, which a check of the comments before each token alone
--- would not see.
local function test_a_comment_lost_at_the_end_of_the_file_is_a_difference()
  differs("x = 1\n-- c\n", "x = 1\n", "the comment at 2:1 was lost")
  differs("x = 1\n-- c\n-- d\n", "x = 1\n-- c\n", "the comment at 3:1 was lost")
  differs("-- only\n", "", "the comment at 1:1 was lost")
  differs("x = 1 -- c\n", "x = 1\n", "the comment at 1:7 was lost")
  same("x = 1\n-- c\n", "x = 1\n\n\n-- c")
end

local function test_a_comment_before_an_operator_that_moves_behind_the_code_is_no_difference()
  same("local x = a\n  -- c\n  + b\n", "local x = a +\n  -- c\n  b\n")
  same("local x = a -- c\n  or b\n", "local x = a or -- c\n  b\n")
  -- Moved behind two tokens, or in front of a token that is no operator, it is.
  differs("local x = a\n  -- c\n  + b\n", "local x = a +\n  b -- c\n", "")
  differs("local x = a\n  -- c\n  + b\n", "local x = a +\n  b\n  -- c\n", "comes after")
end

local function test_a_comment_before_an_operator_after_a_parenthesis_or_a_cast_moves_with_it()
  same("local x = (a)\n  -- c\n  + b\n", "local x = (a) +\n  -- c\n  b\n")
  same("local x = a as T\n  -- c\n  or b\n", "local x = a as T or\n  -- c\n  b\n")
  same("local x = f(a)\n  -- c\n  .. g(b)\n", "local x = f(a) ..\n  -- c\n  g(b)\n")
end

local function test_a_doc_comment_parted_from_its_declaration_or_joined_to_one_is_a_difference()
  same("--- doc\nlocal function f() end\n", "--- doc\nlocal function f() end\n")
  differs("--- doc\nlocal function f() end\n", "--- doc\n\nlocal function f() end\n", "doc comment")
  differs("-- doc\n\nlocal function f() end\n", "-- doc\nlocal function f() end\n", "doc comment")
  differs("local record R\n  --- the name\n  name: string\nend\n", "local record R\n  --- the name\n\n  name: string\nend\n",
    "doc comment")
  -- A comment before code that is no declaration documents nothing, whatever lies between.
  same("-- c\nx = 1\n", "-- c\n\nx = 1\n")
  same("if a then\n  -- c\n  b()\nend\n", "if a then\n  -- c\n\n  b()\nend\n")
  -- A comment at the end of a line of code is no doc comment, whatever follows.
  same("x = 1 -- c\nlocal function f() end\n", "x = 1 -- c\nlocal function f() end\n")
  differs("x = 1 -- c\nlocal function f() end\n", "x = 1\n-- c\nlocal function f() end\n", "")
end

local function test_a_source_with_a_shebang_keeps_it()
  differs("#!/bin/cosmic\nx = 1\n", "#!/bin/sh\nx = 1\n", "#!")
  differs("#!/bin/cosmic\nx = 1\n", "x = 1\n", "#!")
end

local function test_a_layout_that_does_not_parse_is_a_difference()
  differs("x = 1\n", "x = = 1\n", "does not parse")
  differs("x = 1\n", "x = 1 end\n", "does not parse")
  local before = Equiv.read("x = = 1\n", "a.tl", "tl")
  local why = Equiv.difference(before, Equiv.read("x = 1\n", "b.tl", "tl"))
  assert(why ~= nil and why:find("the source does not parse", 1, true) ~= nil, tostring(why))
end

local function test_a_declaration_file_is_read_as_one()
  local before = Equiv.read("local record R\n  x: integer\nend\n", "a.d.tl", "decl")
  local after = Equiv.read("local record R x: integer end\n", "b.d.tl", "decl")
  assert(Equiv.difference(before, after) == nil)
  local other = Equiv.read("local record R x: string end\n", "b.d.tl", "decl")
  assert(Equiv.difference(before, other) ~= nil)
end
