--- [`build.fix.layout`] over tiny sources whose breaks [`build.fix.breaks`] decides: one statement to a line, a block
--- on one line only where it reads as one, and the opening of a block to its full form. The cases are the previous
--- formatter's break tests, checked against the text it wrote. Every case also goes through
--- [`build.fix.layout_check`]'s properties: no token or comment changes, the tree is the same, a break is added only
--- where a rule asks for one and alone leaves the tree as it was, and laying out what is laid out changes nothing.
local Check = require("build.fix.layout_check")
local Test = require("cosmic.test")

Test.policy{}

local lays = Check.lays

--- Asserts that `source` lays out as itself.
local function keeps(source: string)
  lays(source, source)
end

local function test_two_statements_on_a_line_are_parted()
  lays("a = 1 b = 2\n", "a = 1\nb = 2\n")
  lays("a = 1 b = 2 c = 3\n", "a = 1\nb = 2\nc = 3\n")
  lays("do\n  f() g()\nend\n", "do\n  f()\n  g()\nend\n")
  lays("f()   g() -- c\nh()\n", "f()\ng() -- c\nh()\n")
end

local function test_a_block_of_one_short_statement_stays_on_its_line()
  keeps("if x then return 1 end\n")
  keeps("for i = 1, 10 do print(i) end\n")
  keeps("for k, v in pairs(t) do print(k) end\n")
  keeps("while a > 0 do a = a - 1 end\n")
  keeps("repeat a = 1 until a > 0\n")
  keeps("local function f() return 1 end\n")
  keeps("function M.f() return 1 end\n")
  keeps("f(function(x) return x end)\n")
  keeps("if x then a() else b() end\n")
  keeps("while f() do end\n")
  keeps("do a() end\n")
  keeps("local f = function() return 1 end\n")
end

local function test_a_block_of_two_statements_is_opened()
  lays("if x then a() b() end\n", "if x then\n  a()\n  b()\nend\n")
  lays("repeat a() b() until c\n", "repeat\n  a()\n  b()\nuntil c\n")
  lays("local function f() a() return 1 end\n", "local function f()\n  a()\n  return 1\nend\n")
  lays("while x do a() b() end\n", "while x do\n  a()\n  b()\nend\n")
  lays("for i = 1, 2 do a() b() end\n", "for i = 1, 2 do\n  a()\n  b()\nend\n")
  lays("do a() b() end\n", "do\n  a()\n  b()\nend\n")
end

--- A block holding a block is opened; the one inside stays on its line when it holds one statement.
local function test_a_block_holding_a_block_is_opened()
  lays("for _, v in ipairs(t) do if v then n = n + 1 end end\n",
    "for _, v in ipairs(t) do\n  if v then n = n + 1 end\nend\n")
  lays("do do a() end end\n", "do\n  do a() end\nend\n")
  lays("if x then match f(y) do\n| (true) then a()\nend end\n", "if x then\n  match f(y) do\n  | (true) then a()\n  end\nend\n")
end

local function test_an_if_of_three_branches_is_opened()
  lays("if a then x = 1 elseif b then x = 2 else x = 3 end\n",
    "if a then\n  x = 1\nelseif b then\n  x = 2\nelse\n  x = 3\nend\n")
  keeps("if a then x = 1 elseif b then x = 2 end\n")
end

--- A block ending past the width is opened; one ending on it is not.
local function test_a_block_past_the_width_is_opened()
  local at_width = "if x then f(\"" .. string.rep("a", 100 - #"if x then f(\"\") end") .. "\") end"
  assert(#at_width == 100)
  keeps(at_width .. "\n")
  local past = "if x then f(\"" .. string.rep("a", 101 - #"if x then f(\"\") end") .. "\") end"
  lays(past .. "\n", "if x then\n  " .. past:sub(#"if x then " + 1, -#" end" - 1) .. "\nend\n")
end

--- The width counts the output, not the source: the spaces a layout drops do not count, the ones it adds do.
local function test_the_width_is_that_of_the_output()
  local value = string.rep("a", 100 - #"if x then y = f(\"\") end")
  keeps("if x then y = f(\"" .. value .. "\") end\n")
  lays("if  x  then  y=f(\"" .. value .. "\")  end\n", "if x then y = f(\"" .. value .. "\") end\n")
  local past = "if x then y = f(\"" .. value .. "a\") end"
  lays("if x then y=f(\"" .. value .. "a\") end\n", "if x then\n  y = f(\"" .. value .. "a\")\nend\n")
  assert(#past == 101)
end

--- A table's comma, dropped before the `}`, does not count either.
local function test_a_comma_a_layout_drops_does_not_count_toward_the_width()
  local pad = string.rep("a", 100 - #"if x then y = { 1, \"\" } end")
  keeps("if x then y = { 1, \"" .. pad .. "\" } end\n")
  lays("if x then y = { 1, \"" .. pad .. "\", } end\n", "if x then y = { 1, \"" .. pad .. "\" } end\n")
end

--- A block part on one line and part off it is opened the whole way.
local function test_a_half_open_block_is_opened()
  lays("if x then a()\nend\n", "if x then\n  a()\nend\n")
  lays("if x then\n  a() end\n", "if x then\n  a()\nend\n")
  lays("if x then   return 1\n   end\n", "if x then\n  return 1\nend\n")
  lays("if x then a() else\n  b()\nend\n", "if x then\n  a()\nelse\n  b()\nend\n")
  lays("while x do a()\n  b() end\n", "while x do\n  a()\n  b()\nend\n")
  lays("local function f() a()\nend\n", "local function f()\n  a()\nend\n")
end

--- A block already open is left as it is, whatever it holds.
local function test_an_open_block_stays_open()
  keeps("if x then\n  a()\nend\n")
  keeps("if x then\n  a()\nelse\n  b()\nend\n")
  keeps("while x do\nend\n")
  keeps("repeat\n  a()\nuntil b\n")
  keeps("f(function()\n  return 1\nend)\n")
end

--- A function literal opened inside a block on one line leaves that block no longer on one line, and it is opened
--- in turn.
local function test_opening_an_inner_block_opens_the_one_around_it()
  lays("if x then f(function() a() b() end) end\n",
    "if x then\n  f(function()\n    a()\n    b()\n  end)\nend\n")
  lays("local function g() return function() a() b() end end\n",
    "local function g()\n  return function()\n    a()\n    b()\n  end\nend\n")
end

--- A function literal inside a block on one line is judged with it, and alone when the block is open.
local function test_a_function_literal_inside_is_judged_alone()
  keeps("if x then f(function() a() end) end\n")
  keeps("f(function() a() end, function() b() end)\n")
  lays("f(function() a() b() end, function() c() end)\n", "f(function()\n  a()\n  b()\nend, function() c() end)\n")
end

--- A statement moved onto a line of its own takes the lines that continue it along, indented from it.
local function test_a_moved_statement_carries_its_continuation()
  lays("a = 1 b = f(1,\n             2)\n", "a = 1\nb = f(1,\n  2)\n")
  lays("do\n  a = 1 b = {\n    x = 1,\n  }\nend\n", "do\n  a = 1\n  b = {\n    x = 1,\n  }\nend\n")
  lays("a = 1 b = x ..\n  y\n", "a = 1\nb = x ..\n  y\n")
end

--- A block behind another statement on its line is judged where it is written once parted from it, not where it
--- began.
local function test_a_block_is_judged_after_its_statement_moves()
  local first = "local s = f(\"" .. string.rep("a", 70) .. "\")"
  lays(first .. " if s ~= 0 then return s end\n", first .. "\nif s ~= 0 then return s end\n")
end

--- A block inside one opened up is judged where it lands, not at the column it had behind the block around it.
local function test_an_inner_block_is_judged_where_it_lands()
  local call = "f(\"" .. string.rep("a", 60) .. "\")"
  lays("for _, v in ipairs(t) do if v then " .. call .. " end end\n",
    "for _, v in ipairs(t) do\n  if v then " .. call .. " end\nend\n")
end

--- A `repeat` whose condition runs onto another line is no block on one line.
local function test_a_repeat_whose_condition_spans_lines_is_opened()
  lays("repeat a() until x and\n  y\n", "repeat\n  a()\nuntil x and\n    y\n")
end

--- A comment in front of a closing word that moves trails the code it followed.
local function test_a_comment_before_a_moved_closer_trails_its_code()
  lays("if x then a() b() -- c\nend\n", "if x then\n  a()\n  b() -- c\nend\n")
  lays("if x then a() b() -- c\nelse d() end\n", "if x then\n  a()\n  b() -- c\nelse\n  d()\nend\n")
  lays("if x then a() -- c\nend\n", "if x then\n  a() -- c\nend\n")
end

--- An `else` written on an open line is opened onto its own, and so is the `end` of a function literal whose body
--- opened on its first line.
local function test_a_keyword_or_body_alone_on_an_open_line_is_opened()
  lays("if x then\n  a() else\n  b()\nend\n", "if x then\n  a()\nelse\n  b()\nend\n")
  lays("f(function() a()\nend)\n", "f(function()\n  a()\nend)\n")
  lays("if x then\n  a()\nelseif y then b() end\n", "if x then\n  a()\nelseif y then\n  b()\nend\n")
end

--- The `end` of a function literal that is opened begins a line level with the line the function is written on, and
--- the statements of the function are indented from it.
local function test_an_opened_function_literal_is_indented_from_the_line_it_begins_on()
  lays("run(a,\n  function() x() y() end)\n", "run(a,\n  function()\n    x()\n    y()\n  end)\n")
  lays("local t = { f = function() x() y() end }\n", "local t = { f = function()\n  x()\n  y()\nend }\n")
  lays("local t = {\n  f = function() x() y() end,\n}\n", "local t = {\n  f = function()\n    x()\n    y()\n  end,\n}\n")
end

--- A declaration keeps its source breaks, and so do the `if` expression and the arms of a `match`.
local function test_declarations_the_if_expression_and_match_arms_keep_their_breaks()
  keeps("local record R x: integer y: string end\n")
  keeps("local v = if a then b else c end\n")
  keeps("local v = if a then b elseif c then d else e end\n")
  keeps("match f(x) do\n| (true, v) then print(v)\n| (false, _) then\n  print(1)\nend\n")
end

--- An arm of a `match` that holds more than one statement, or a block, begins its body on a line of its own.
local function test_a_match_arm_of_two_statements_is_opened()
  lays("match f(x) do\n| (true) then a() b()\nend\n", "match f(x) do\n| (true) then\n  a()\n  b()\nend\n")
  lays("match f(x) do\n| (true) then if y then z() end\nend\n", "match f(x) do\n| (true) then\n  if y then z() end\nend\n")
  keeps("match f(x) do\n| (true) then a()\nend\n")
  keeps("match f(x) do\n| (true) then\n  a()\n  b()\nend\n")
end

--- A method is a block like a function, and the statements of a class are parted like any.
local function test_a_method_is_a_block()
  keeps("local class C\n  function get(self): integer return self.x end\nend\n")
  lays("local class C\n  function bump(self) a() b() end\nend\n", "local class C\n  function bump(self)\n    a()\n    b()\n  end\nend\n")
end

--- A declaration is no block statement: a block that holds one on its own line stays on that line, as the previous
--- formatter left it, and the declaration's members keep the line they share.
local function test_a_block_that_holds_a_declaration_on_one_line_stays_on_its_line()
  keeps("if x then local record R x: integer end end\n")
  keeps("if x then local interface I x: integer end end\n")
  keeps("if x then local class C x: integer end end\n")
  keeps("if x then local enum E \"a\" \"b\" end end\n")
  keeps("do local record R x: integer y: string end end\n")
  keeps("local function f() local record R x: integer end end\n")
  -- A declaration over several lines is not on one, and opens the block that holds it.
  lays("if x then local record R\n  x: integer\nend end\n", "if x then\n  local record R\n    x: integer\n  end\nend\n")
  -- A block still opens for the statements it holds beside the declaration.
  lays("if x then local record R x: integer end y() end\n", "if x then\n  local record R x: integer end\n  y()\nend\n")
end

--- A class written on one line is written as it is, as a record is: no method in it is opened, however many statements
--- it holds or wide the line is.
local function test_a_class_on_one_line_stays_as_written_and_no_method_in_it_is_opened()
  keeps("local class C function get(self): integer return self.x end end\n")
  keeps("local class C x: integer function bump(self) a() b() end end\n")
  keeps("local class C function m(self) a() b() end function n(self) if x then c() d() end end end\n")
  keeps("if x then local class C function m(self) a() b() end end end\n")
  keeps("local class C function a_rather_long_method(self, first: integer, second: integer): integer return first + second + self.count end end\n")
  keeps("local record R x: function(): integer y: string end\n")
  keeps("local enum E \"a\" \"b\" end\n")
  -- Over several lines a method is a block like any.
  lays("local class C\n  x: integer function m(self) a() b() end\nend\n",
    "local class C\n  x: integer function m(self)\n    a()\n    b()\n  end\nend\n")
end

--- An `if` expression keeps its breaks, and so does a function written in it: the function is not opened, or its
--- statements parted, whatever it holds.
local function test_a_function_written_in_an_if_expression_stays_as_written()
  keeps("local v = if a then function() b() c() end else d end\n")
  keeps("local v = if a then function() return 1 end else function() b() c() end end\n")
  keeps("local v = if a then f(function() b() c() end) elseif e then g() else function(x) if x then y() z() end end end\n")
  keeps("local v = if a then function()\n  b() c()\nend else d end\n")
  keeps("f(if a then function() b() c() end else d end)\n")
  -- A function beside the expression is judged as any is.
  lays("local v = if a then b else c end f(function() d() e() end)\n",
    "local v = if a then b else c end\nf(function()\n  d()\n  e()\nend)\n")
end

local function test_the_width_of_a_block_on_one_line_counts_bytes()
  -- Forty characters of two bytes make a line of 100 bytes, 60 characters: it ends at column 100 and stays. One more
  -- makes it 102 bytes, which opens it, though it is 61 characters long.
  local fits = "if x then y = \"" .. ("é"):rep(40) .. "\" end"
  assert(#fits == 100, tostring(#fits))
  keeps(fits .. "\n")
  local over = "if x then y = \"" .. ("é"):rep(41) .. "\" end"
  lays(over .. "\n", "if x then\n  y = \"" .. ("é"):rep(41) .. "\"\nend\n")
end

local function test_a_source_with_no_break_to_add_is_left_alone()
  keeps("local x = 1\n")
  keeps("")
  keeps("-- c\n")
  keeps("#!/bin/cosmic\nx = 1\n")
end
