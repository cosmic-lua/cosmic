--- Where a comment ends up, checked against the exact text expected.
---
--- Comments are the one thing this renderer carries that has no node of
--- its own. Everything else is written from the tree and cannot end up
--- anywhere but where its node says; a comment is placed by line and
--- column against the code around it. That can go wrong in two ways,
--- and this file is about both.
---
--- A comment can be lost. [`build.fix.equiv`] reparses what was written
--- and compares the comments of both sides, which catches a renderer
--- that drops one, unless the comment reached neither side. A comment
--- ending at the end of the file with no newline after it would not:
--- tl's lexer records a short comment when it reads the newline that
--- ends it, so input running out inside one carries it nowhere.
--- [`patch/tl/05-comment-at-end-of-input.txt`] ends it at the end of the
--- input instead, which puts it on both sides of the comparison. The
--- first tests here hold that.
---
--- A `--#...` run is a comment read through the lexer's pragma states,
--- not its short-comment state: the run is cut as a pragma token first
--- and turned back into a short comment unless it spells `--#pragma`
--- exactly. Two things can lose a comment there. Input running out
--- inside the run leaves the lexer in a state the end-of-input guard
--- must name, or `--#region` at the end of a file goes the way an
--- ordinary comment would. And removing the pragma token discards the
--- comments it had already taken, so a comment in front of such a run
--- is lost even with a newline after it.
--- [`patch/tl/06-comment-before-a-pragma-run.txt`] covers the second.
---
--- And a comment can move. `--[[ q ]] print(1)` is a comment the code
--- was written behind, and writing it after the code says something
--- different about the line while parsing the same and carrying the
--- same comments. No comparison over either tree catches that; only
--- the text does. The last part of this file is that text, one shape
--- of enclosing construct at a time.

local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local fix = require("build.fix")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Run the whole pipeline over `source`, asserting it succeeded.
local function fixed(source: string): string
  local result, trouble = fix.source(built, source, "fixture.tl")
  assert(result ~= nil, "fix refused it: " .. tostring(trouble))
  return result.source
end

--- Assert `source` is written back out as `want`.
local function writes(source: string, want: string)
  local got = fixed(source)
  assert(got == want, "got:\n" .. got .. "\nwant:\n" .. want)
end

--- Assert `source` is written back out unchanged.
local function keeps(source: string)
  writes(source, source)
end

--- Every comment the parse of `source` carries, in source order.
local function carried(source: string): {string}
  local parsed, trouble = ast.parse(built, source, "fixture.tl")
  assert(parsed ~= nil, "parse failed: " .. tostring(trouble))
  return equiv.comments(parsed.tokens)
end

--- Assert the pipeline refuses `source`, with a message holding `why`.
local function refuses(source: string, why: string)
  local result, trouble = fix.source(built, source, "fixture.tl")
  assert(result == nil, "fix accepted it and wrote:\n" .. tostring(
    result ~= nil and result.source or ""))
  assert(trouble:find(why, 1, true) ~= nil,
    "refused with " .. trouble .. ", wanted one naming " .. why)
end

--- Assert `source` carries exactly the comments `source .. "\n"` does.
---
--- The version with the final newline is the ground truth throughout:
--- it is the same file, and a newline at the end of it is layout rather
--- than content, so a comment that survives one and not the other is a
--- comment the end of the input ate.
local function carries_what_a_final_newline_would(source: string)
  local without, with = carried(source), carried(source .. "\n")
  assert(#without == #with,
    source .. ": carried " .. #without .. " comments without a final " ..
      "newline and " .. #with .. " with one")
  for i, text in ipairs(with) do
    assert(without[i] == text,
      source .. ": comment " .. i .. " is " .. tostring(without[i]) ..
        ", not " .. text)
  end
end

--- A file that ends inside a comment carries the same comments as the
--- same file with the newline it was missing.
---
--- This is the property under every end-of-file case below, and the
--- renderer cannot make up for it: a comment the lexer never hands back
--- is absent from the rendered tree and from the tree the result
--- reparsed to, so the comparison agrees and the file is rewritten
--- without it.
local function test_a_comment_ending_at_the_end_of_input_still_reaches_a_token()
  for _, source in ipairs({
      "local a = 1\nprint(a) -- why",
      "local a = 1\nprint(a)\n-- the end",
      "local a = 1\nprint(a)\n-- one\n-- two",
      "local q = [[\nhi\n]] -- tail",
      "local a = 1\nprint(a)\n--",
      "local a = 1\nprint(a)\n--[",
  }) do
    carries_what_a_final_newline_would(source)
  end
end

--- A file with no final newline gets one, and keeps the comment that
--- was the last thing in it. The newline is the renderer's own rule --
--- exactly one at the end, whatever the source had -- and losing the
--- comment on the way is what this is here about.
local function test_a_trailing_comment_at_the_end_of_a_file_with_no_newline()
  writes("local a = 1\nprint(a) -- why", "local a = 1\nprint(a) -- why\n")
  writes("local a = 1\nprint(a) --[[ blk ]]",
    "local a = 1\nprint(a) --[[ blk ]]\n")
end

--- The same for a comment on a line of its own, and for a run of them:
--- every one of them, not every one but the last.
local function test_own_line_comments_at_the_end_of_a_file_with_no_newline()
  writes("local a = 1\nprint(a)\n-- the end",
    "local a = 1\nprint(a)\n-- the end\n")
  writes("local a = 1\nprint(a)\n-- one\n-- two",
    "local a = 1\nprint(a)\n-- one\n-- two\n")
  writes("local a = 1\nprint(a)\n--[[ own line ]]",
    "local a = 1\nprint(a)\n--[[ own line ]]\n")
end

--- And for one after a long string's own `]]`, which is the case where
--- the comment is not the first thing the lexer met on its line.
local function test_a_comment_after_a_long_string_at_the_end_of_a_file()
  writes("local q = [[\nhi\n]] -- tail", "local q = [[\nhi\n]] -- tail\n")
end

--- A `--` and a `--[` that got no further are comments too, one and two
--- characters long, and the end of the file does not excuse dropping
--- them any more than it excuses dropping a spelled-out one.
local function test_a_comment_that_got_no_further_than_its_dashes()
  writes("local a = 1\nprint(a)\n--", "local a = 1\nprint(a)\n--\n")
  writes("local a = 1\nprint(a)\n--[", "local a = 1\nprint(a)\n--[\n")
end

--- A `--#` run that does not spell `--#pragma` is an ordinary short
--- comment, and the end of the input ends it where a newline would.
--- The lexer reads such a run through its pragma states, not the
--- short-comment state. Unless the end-of-input guard names them, a
--- `--#region` fold marker or a `--#tail` note at the end of a file
--- with no final newline reaches no token, and a comment that reaches
--- no token is absent from both sides of the comparison meant to catch
--- a lost one.
local function test_a_pragma_shaped_comment_at_the_end_of_input()
  for _, source in ipairs({
      "--#region\nprint(1)\n--#endregion",
      "print(1) --#tail",
      "--#foo",
      "--#",
      "print(1)\n--#region\n--#endregion",
      "--#pragmatic",
  }) do
    carries_what_a_final_newline_would(source)
  end
end

--- And the whole pipeline keeps it, which is the property the file is
--- rewritten under: the run comes back out where it was written, with
--- the one final newline the renderer always ends a file with.
local function test_a_pragma_shaped_comment_survives_the_rewrite()
  writes("--#region\nprint(1)\n--#endregion",
    "--#region\nprint(1)\n--#endregion\n")
  writes("print(1) --#tail", "print(1) --#tail\n")
  writes("--#foo", "--#foo\n")
  writes("--#", "--#\n")
end

--- A run that does spell `--#pragma` is a pragma token, not a comment,
--- and the end of the input does not turn it into one: if the
--- end-of-input guard did not name the pragma states, `--#pragma` with
--- no newline after it would vanish from the token stream and the file
--- would be rewritten without it. An incomplete one is refused, and a
--- whole one is written back.
local function test_a_real_pragma_at_the_end_of_input_is_still_a_pragma()
  refuses("--#pragma", "expected pragma name")
  refuses("--#pragma\n", "expected pragma name")
  writes("--#pragma arity on", "--#pragma arity on\n")
  keeps("--#pragma arity on\n")
end

--- A comment in front of a `--#` run is kept. The run is cut as a
--- pragma token before the lexer knows it is not one, and that token
--- takes the comments waiting to be attached. Removing the token from
--- the list to undo it would discard those comments, and the comment
--- above a fold marker would be lost whether or not the file ended in
--- a newline.
local function test_a_comment_in_front_of_a_pragma_shaped_comment()
  keeps("-- hello\n--#region\nprint(1)\n")
  keeps("--[[ b ]] --#region\nprint(1)\n")
  keeps("-- one\n-- two\n--#region\n--#endregion\nprint(1)\n")
  writes("print(1)\n-- hello\n--#endregion",
    "print(1)\n-- hello\n--#endregion\n")
  assert(#carried("-- hello\n--#region\nprint(1)\n") == 2,
    "a comment in front of a `--#` run was dropped")
end

--- A comment the source wrote in front of a statement, on that
--- statement's line, stays in front of it. Writing it behind the
--- statement instead would parse and carry the same comments, but say
--- the code was commented rather than that the comment introduced it.
local function test_a_comment_in_front_of_a_statement_on_its_own_line()
  keeps("local a = 1\n--[[ r ]] local x = 2\nprint(a, x)\n")
end

--- The same inside each shape of block. The renderer indents the line,
--- so the comment leads it and the code follows one space along.
local function test_a_comment_in_front_of_a_statement_inside_a_block()
  keeps("if true then\n  --[[ q ]] print(1)\nend\n")
  keeps("while true do\n  --[[ w ]] break\nend\n")
  keeps("for i = 1, 3 do\n  --[[ f ]] print(i)\nend\n")
  keeps("local function g()\n  --[[ fn ]] return 1\nend\nprint(g())\n")
  keeps("do\n  --[[ d ]] print(1)\nend\n")
end

--- The same around each spelling of a `global` statement, a
--- `local macroexp` and a pragma: in front of one, inside one, and
--- behind one.
local function test_comments_around_globals_macroexps_and_pragmas()
  keeps("-- g\nglobal x = 1 -- t\nprint(x)\n")
  keeps("global --[[ c ]] y: integer\n")
  keeps("--[[ f ]] global function g()\n  --[[ b ]] return 1\nend\n")
  keeps("--- doc\nfunction h() end -- t\n")
  keeps("-- r\nglobal record R\n  -- x\n  x: integer\nend\n")
  keeps("-- a\nglobal type T = integer -- t\n")
  keeps("global type U -- t\n")
  keeps("-- m\nlocal macroexp m(a: integer): integer\n" ..
      "  -- body\n  return a + 1 -- sum\nend\n")
  keeps("-- p\n--#pragma arity on\nprint(1)\n")
end

--- A statement moves by the distance its line moves, not its first
--- keyword: the keyword sits further along than the line starts once a
--- comment is written in front of it, and every continuation line must
--- move by the line's distance or land in the wrong column.
local function test_a_statement_led_by_a_comment_carries_its_own_continuation()
  keeps("if true then\n  --[[ q ]] print(1,\n    2)\nend\n")
end

--- One line can lead a statement with more than one comment, written
--- as the same run as any other line's comments.
local function test_several_comments_in_front_of_one_statement()
  keeps("if true then\n  --[[ a ]] --[[ b ]] print(1)\nend\n")
end

--- A table entry is a continuation line, not a statement, so its column
--- is carried over rather than chosen, and a comment in front of the
--- entry leads that line at the column the source gave it.
local function test_a_comment_in_front_of_a_table_entry()
  keeps("local t = {\n  --[[ a ]] 1,\n  2,\n}\nprint(#t)\n")
  keeps("f(\n  --[[ c ]] 1)\n")
end

--- A comment with code on both sides opens no line and is written back
--- between the two, with no line break involved.
local function test_a_comment_between_code_on_one_line()
  keeps("local f = print\nf(--[[ x ]] 1)\n")
  keeps("local --[[ c ]] x = 1\nprint(x)\n")
  keeps("local x = --[[ c ]] 1\nprint(x)\n")
  keeps("local a = 1 --[[ t ]] + 2\nprint(a)\n")
  keeps("if --[[ c ]] true then print(1) end\n")
  keeps("do --[[ c ]] local x = 2 end\n")
  keeps("do local x = 1 --[[ c ]] end\n")
end

--- A comment between two statements on one line goes with the second
--- when the break between them is made, opening its line.
local function test_a_comment_between_two_statements_opens_the_second_ones_line()
  writes("print(1) --[[ c ]] print(2)\n", "print(1)\n--[[ c ]] print(2)\n")
end

--- A long comment that opens on the line above and closes on the
--- code's line is written where it was too: the break the source had in
--- front of the code is inside the comment's text, so the renderer has
--- none to write.
local function test_a_long_comment_opening_above_the_code_it_closes_beside()
  keeps("local a = 1\nprint(a) --[[ c\n]] print(2)\n")
  keeps("local a = 1\nprint(a) --[[ c\n]] --[[ d ]] print(2)\n")
  keeps("local a = 1\nprint(a) --[[ c\n]] -- tail\nprint(2)\n")
end

--- A comment written in front of an operator comes out in front of the
--- node after it. This is the gap the TODO at `emit.ahead` describes:
--- comments are placed when a node's lead is written, and the `=`, `,`,
--- `.` or `in` the renderer writes itself between two nodes is not a
--- lead, so a comment in front of one is not reached until the operator
--- is written.
---
--- These assertions pin the gap's shape, so that closing it shows up
--- as they flip rather than as a silent change of behaviour. Nothing in
--- this tree meets it: it takes a comment with code on both sides, and
--- a `---` doc comment runs to the end of its line.
local function test_a_comment_in_front_of_an_operator_moves_past_it()
  writes("local a --[[ c ]] = 1\nprint(a)\n",
    "local a = --[[ c ]] 1\nprint(a)\n")
  writes("local x: integer --[[ c ]] = 1\nprint(x)\n",
    "local x: integer = --[[ c ]] 1\nprint(x)\n")
  writes("local t = { 1--[[ c ]], 2 }\nprint(#t)\n",
    "local t = { 1, --[[ c ]] 2 }\nprint(#t)\n")
  writes("for k, v --[[ c ]] in pairs({}) do print(k, v) end\n",
    "for k, v in --[[ c ]] pairs({}) do print(k, v) end\n")
end

--- The gap costs placement only: the comment is still there, and the
--- moved result is its own fixed point, so a second pass does not move
--- it a token further.
local function test_a_comment_moved_past_an_operator_is_kept_and_settles()
  for _, source in ipairs({
      "local a --[[ c ]] = 1\nprint(a)\n",
      "local t = { 1--[[ c ]], 2 }\nprint(#t)\n",
      "for k, v --[[ c ]] in pairs({}) do print(k, v) end\n",
      "local --[[ c ]] function h() end\nh()\n",
  }) do
    local once = fixed(source)
    assert(once:find("--[[ c ]]", 1, true) ~= nil,
      source .. ": the comment was dropped rather than moved")
    assert(fixed(once) == once,
      source .. ": a second pass moved it again:\n" .. fixed(once))
  end
end

--- The lines of a long comment inside a record body are the comment's
--- own text: the body moves with its statement, and they stay as they
--- were.
local function test_a_long_comment_in_a_moved_record_keeps_its_lines()
  writes("  local type T = record\n  --[=[ keep\n\n   this ]=]\n  end\n",
    "local type T = record\n--[=[ keep\n\n   this ]=]\nend\n")
end

--- A long comment closing on a later line ends the run of trailing
--- comments there unless nothing stands between them: a comment after
--- code still to be written waits for that code, and one after code
--- already written follows the `]]`.
local function test_comments_after_a_long_one_closes_wait_for_their_code()
  keeps("while { f = --[[ c\n]] a } do -- d\n  return a\nend\n")
  writes("x = f(1 --[[ c\n]], -- d\n  2)\n", "x = f(1, --[[ c\n]] -- d\n  2)\n")
end

--- A comment written into a continuation line, behind a token the
--- renderer writes itself, stays in front of the code it was written
--- before, and one further along stays there.
local function test_a_comment_inside_a_continuation_line_stays_before_its_code()
  writes("b -- why\n= --[[ c ]] 1\n", "b = -- why\n  --[[ c ]] 1\n")
  keeps("b = function(a,\n  --[[ x ]] ...: y): --[[ z ]] e end\n")
end

--- A comment between a type alias's name and its `=` is kept, moved
--- one token along as any comment in front of an operator is.
local function test_a_comment_in_a_type_alias_is_kept()
  writes("global type T --[[ c ]] = {string: integer}\n",
    "global type T = --[[ c ]] {string: integer}\n")
end

--- A long comment after a unary `-` keeps its space from it, or the two
--- would read as `---`, a line comment.
local function test_a_long_comment_after_a_unary_minus()
  keeps("x = - --[[ c ]] y\n")
end

--- A line comment before an index's `]` keeps the line break after it.
local function test_a_line_comment_before_a_closing_bracket()
  keeps("x = a[a -- why\n]\n")
  keeps("x = { [a -- why\n] = 1 }\n")
end

--- A comment between a statement and its `;` stays in front of the
--- `;`: the parser hangs it on that token, and writing the `;` first
--- would hang it on the next statement's.
local function test_a_comment_before_a_semicolon_stays_before_it()
  keeps("local a = 1 --[[ x ]] ; -- y\nlocal b = 2\n")
  writes("f() --[[ x ]] ; g()\n", "f() --[[ x ]] ;\ng()\n")
  keeps("local a = 1\n--[[ x ]] ; -- y\nlocal b = 2\n")
  keeps("local a = 1 --[[ x\n]] ; -- y\nlocal b = 2\n")
  keeps("do f() --[[ x ]] ; end\n")
  keeps("f() --[[ x ]] ;\n")
end
