--- The line breaks `cosmic fix` adds ([`build.fix.breaks`]), checked
--- against the exact text expected and through the whole verb, so each
--- case is reparsed and compared for meaning too.

local fix = require("build.fix")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Assert `source` is written back out as `want`.
local function writes(source: string, want: string)
  local result, trouble = fix.source(built, source, "fixture.tl")
  assert(result ~= nil, "fix refused it: " .. tostring(trouble))
  assert(result.source == want, "got:\n" .. result.source .. "\nwant:\n" .. want)
end

--- Assert `source` is written back out unchanged.
local function keeps(source: string)
  writes(source, source)
end

local function test_two_statements_on_a_line_are_parted()
  writes("a = 1 b = 2\n", "a = 1\nb = 2\n")
  writes("a = 1; b = 2; c = 3\n", "a = 1\nb = 2\nc = 3\n")
  writes("do\n  f() g()\nend\n", "do\n  f()\n  g()\nend\n")
end

local function test_a_block_of_one_short_statement_stays_on_its_line()
  keeps("if x then return 1 end\n")
  keeps("for i = 1, 10 do print(i) end\n")
  keeps("while a > 0 do a = a - 1 end\n")
  keeps("repeat a = 1 until a > 0\n")
  keeps("local function f() return 1 end\n")
  keeps("f(function(x) return x end)\n")
  keeps("if x then a() else b() end\n")
  keeps("while f() do end\n")
end

local function test_a_block_of_two_statements_is_opened()
  writes("if x then a() b() end\n", "if x then\n  a()\n  b()\nend\n")
  writes("repeat a() b() until c\n", "repeat\n  a()\n  b()\nuntil c\n")
  writes("local function f() a() return 1 end\n",
         "local function f()\n  a()\n  return 1\nend\n")
end

--- A block holding a block is opened; the one inside stays on its line
--- when it holds one statement.
local function test_a_block_holding_a_block_is_opened()
  writes("for _, v in ipairs(t) do if v then n = n + 1 end end\n",
         "for _, v in ipairs(t) do\n  if v then n = n + 1 end\nend\n")
end

local function test_an_if_of_three_branches_is_opened()
  writes("if a then x = 1 elseif b then x = 2 else x = 3 end\n",
         "if a then\n  x = 1\nelseif b then\n  x = 2\nelse\n  x = 3\nend\n")
end

--- A block ending past the width is opened; one ending on it is not.
local function test_a_block_past_the_width_is_opened()
  local at_width = "if x then f(\"" .. string.rep("a", 100 - #"if x then f(\"\") end") .. "\") end"
  assert(#at_width == 100)
  keeps(at_width .. "\n")
  local past = "if x then f(\"" .. string.rep("a", 101 - #"if x then f(\"\") end") .. "\") end"
  writes(past .. "\n", "if x then\n  " .. past:sub(#"if x then " + 1, -#" end" - 1) .. "\nend\n")
end

--- A block part on one line and part off it is opened the whole way.
local function test_a_half_open_block_is_opened()
  writes("if x then a()\nend\n", "if x then\n  a()\nend\n")
  writes("if x then\n  a() end\n", "if x then\n  a()\nend\n")
end

--- A function literal opened inside a block on one line leaves that
--- block no longer on one line, and it is opened in turn.
local function test_opening_an_inner_block_opens_the_one_around_it()
  writes("if x then f(function() a() b() end) end\n",
         "if x then\n  f(function()\n    a()\n    b()\n  end)\nend\n")
end

--- A `;` a break replaces goes; one the parser needs, or that a comment
--- hangs on, or that opens a block, stays.
local function test_a_semicolon_goes_only_where_a_break_replaces_it()
  writes("f(); (g)()\n", "f();\n(g)()\n")
  writes("f() --[[ c ]] ; g()\n", "f() --[[ c ]] ;\ng()\n")
  writes("do ; a() b() end\n", "do ;\n  a()\n  b()\nend\n")
  writes("do a() b(); end\n", "do\n  a()\n  b()\nend\n")
end

--- A statement moved onto a line of its own keeps the lines that
--- continue it where they were relative to it.
local function test_a_moved_statement_carries_its_continuation()
  writes("a = 1; b = f(1,\n             2)\n", "a = 1\nb = f(1,\n      2)\n")
end

--- A block behind another statement on its line is judged where it is
--- written once parted from it, not where it began.
local function test_a_block_is_judged_after_its_statement_moves()
  local first = "local s = f(\"" .. string.rep("a", 70) .. "\")"
  writes(first .. "; if s ~= 0 then return s end\n", first .. "\nif s ~= 0 then return s end\n")
end

--- A `return;` keeps its `;` when the `end` after it moves: the empty
--- value list opens on it.
local function test_an_empty_return_keeps_its_semicolon()
  writes("if x then a() return; end\n", "if x then\n  a()\n  return;\nend\n")
  writes("local function f() a() return; end\n", "local function f()\n  a()\n  return;\nend\n")
end

--- A `repeat` whose condition runs onto another line is no block on
--- one line.
local function test_a_repeat_whose_condition_spans_lines_is_opened()
  writes("repeat a() until x and\n  y\n", "repeat\n  a()\nuntil x and\n  y\n")
end

--- A function literal inside a one-line block's statement is judged on
--- its own, and does not open the block around it.
local function test_a_function_literal_inside_is_judged_alone()
  keeps("if x then f(function() a() end) end\n")
end

--- A block inside one opened up is judged where it lands, not at the
--- column it had behind the block around it.
local function test_an_inner_block_is_judged_where_it_lands()
  local call = "f(\"" .. string.rep("a", 60) .. "\")"
  writes("for _, v in ipairs(t) do if v then " .. call .. " end end\n",
         "for _, v in ipairs(t) do\n  if v then " .. call .. " end\nend\n")
end

--- A comment in front of a closing keyword that moves trails the code
--- it followed, and the keyword lines up with its block.
local function test_a_comment_before_a_moved_closer_trails_its_code()
  writes("if x then a() b() --[[ c ]] end\n", "if x then\n  a()\n  b() --[[ c ]]\nend\n")
  writes("if x then a() b() --[[ c ]] else d() end\n",
         "if x then\n  a()\n  b() --[[ c ]]\nelse\n  d()\nend\n")
end

--- An `else` written on an open line is opened onto its own, and so is
--- the `end` of a function literal whose body opened on its first line.
local function test_a_keyword_or_body_alone_on_an_open_line_is_opened()
  writes("if x then\n  a() else\n  b()\nend\n", "if x then\n  a()\nelse\n  b()\nend\n")
  writes("f(function() a()\nend)\n", "f(function()\n  a()\nend)\n")
end
