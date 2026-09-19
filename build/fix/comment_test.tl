--- Where a comment ends up, checked against the exact text expected.
---
--- Comments are the one thing this renderer carries that has no node of
--- its own. Everything else is written from the tree and so cannot end
--- up anywhere but where its node says; a comment is placed by LINE and
--- COLUMN against the code around it, and the two ways that can go
--- wrong are the two this file is about.
---
--- A comment can be LOST. `build.fix.equiv` reparses what was written
--- and compares the comments of both sides, which catches a renderer
--- that drops one -- unless the comment never reached either side, and
--- one ending at the end of the file with no newline after it did not:
--- tl's lexer records a short comment when it reads the newline that
--- ends it, so input running out inside one carried it nowhere at all.
--- `patch/tl/05-comment-at-end-of-input.txt` ends it at the end of the
--- input instead, which is what puts it on both sides of the
--- comparison, and what the first tests here hold.
---
--- And a comment can MOVE. `--[[ q ]] print(1)` is a comment the code
--- was written behind, and writing it after the code instead says
--- something different about the line while parsing the same and
--- carrying the same comments -- so no comparison drawn over either
--- tree catches it, and only the text does. The second half of this
--- file is that text, one shape of enclosing construct at a time.

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

--- A file that ends inside a comment carries the same comments as the
--- same file with the newline it was missing.
---
--- This is the property underneath every EOF case below, and the one
--- the renderer cannot make up for on its own: a comment the lexer
--- never hands back is absent from the tree that was rendered AND from
--- the tree the result reparsed to, so the comparison between them
--- agrees and the file is rewritten without it.
local function test_a_comment_ending_at_the_end_of_input_still_reaches_a_token()
  for _, source in ipairs({
    "local a = 1\nprint(a) -- why",
    "local a = 1\nprint(a)\n-- the end",
    "local a = 1\nprint(a)\n-- one\n-- two",
    "local q = [[\nhi\n]] -- tail",
    "local a = 1\nprint(a)\n--",
    "local a = 1\nprint(a)\n--[",
  }) do
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

--- A comment the source wrote in FRONT of a statement, on that
--- statement's own line, stays in front of it. Writing it behind the
--- statement instead is the whole defect: it parses, it carries the
--- same comments, and it says the code was commented rather than the
--- comment introduced the code.
local function test_a_comment_in_front_of_a_statement_on_its_own_line()
  keeps("local a = 1\n--[[ r ]] local x = 2\nprint(a, x)\n")
end

--- The same inside each shape of block. The statement is indented by
--- the renderer, and it is the LINE that gets that indentation, so the
--- comment leads it and the code follows one space along.
local function test_a_comment_in_front_of_a_statement_inside_a_block()
  keeps("if true then\n  --[[ q ]] print(1)\nend\n")
  keeps("while true do\n  --[[ w ]] break\nend\n")
  keeps("for i = 1, 3 do\n  --[[ f ]] print(i)\nend\n")
  keeps("local function g()\n  --[[ fn ]] return 1\nend\nprint(g())\n")
  keeps("do\n  --[[ d ]] print(1)\nend\n")
end

--- A statement moves by the distance its LINE moves, not the distance
--- its first keyword moves: the keyword sits further along than the
--- line starts once a comment is written in front of it, and every line
--- continuing the statement has to move by the line's distance or land
--- in the wrong column.
local function test_a_statement_led_by_a_comment_carries_its_own_continuation()
  keeps("if true then\n  --[[ q ]] print(1,\n    2)\nend\n")
end

--- One line can lead a statement with more than one comment, which is
--- the same run every other line's comments are written as.
local function test_several_comments_in_front_of_one_statement()
  keeps("if true then\n  --[[ a ]] --[[ b ]] print(1)\nend\n")
end

--- A table entry is a continuation line rather than a statement, so its
--- column is carried over rather than chosen -- and a comment in front
--- of the entry leads that line at the column the source gave it.
local function test_a_comment_in_front_of_a_table_entry()
  keeps("local t = {\n  --[[ a ]] 1,\n  2,\n}\nprint(#t)\n")
  keeps("f(\n  --[[ c ]] 1)\n")
end

--- A comment with code on BOTH sides of it opens no line at all, and is
--- written back between the two, with no line break in play anywhere.
local function test_a_comment_between_code_on_one_line()
  keeps("local f = print\nf(--[[ x ]] 1)\n")
  keeps("local --[[ c ]] x = 1\nprint(x)\n")
  keeps("local x = --[[ c ]] 1\nprint(x)\n")
  keeps("local a = 1 --[[ t ]] + 2\nprint(a)\n")
  keeps("if --[[ c ]] true then print(1) end\n")
  keeps("do --[[ c ]] local x = 2 end\n")
  keeps("do local x = 1 --[[ c ]] end\n")
  keeps("print(1) --[[ c ]] print(2)\n")
end

--- And a long comment that OPENS on the line above and closes on the
--- code's own line is written where it was too: the break the source
--- had in front of the code is inside the comment's own text, and there
--- is none left for the renderer to write.
local function test_a_long_comment_opening_above_the_code_it_closes_beside()
  keeps("local a = 1\nprint(a) --[[ c\n]] print(2)\n")
  keeps("local a = 1\nprint(a) --[[ c\n]] --[[ d ]] print(2)\n")
  keeps("local a = 1\nprint(a) --[[ c\n]] -- tail\nprint(2)\n")
end
