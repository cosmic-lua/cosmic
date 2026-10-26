--- [`build.fix.layout`] over tiny sources: the lines of a file. Indentation by block, the words that close a block,
--- blank lines, comments and the end of the file, checked against the text the previous formatter wrote for the same
--- construct (its render and comment tests are where the cases come from). Lines that continue a statement are not
--- laid out yet, so no case here has one.
local Check = require("build.fix.layout_check")
local Test = require("cosmic.test")

Test.policy{}

local lays = Check.lays

--- `text` joined by line breaks, with one at the end.
local function lines(text: {string}): string
  return table.concat(text, "\n") .. "\n"
end

local function test_indentation_is_two_columns_a_level()
  lays("local function f()\n      if x then\n            return 1\n      end\nend\n",
    "local function f()\n  if x then\n    return 1\n  end\nend\n")
  lays("f(function()\n        return 1\n      end)\n", "f(function()\n  return 1\nend)\n")
  lays("do\ndo\ndo\nx()\nend\nend\nend\n", "do\n  do\n    do\n      x()\n    end\n  end\nend\n")
end

local function test_a_function_literal_opens_its_body_one_level_in()
  lays("local f = function()\n      return 1\n    end\ng(function()\n      return 2\n    end)\n",
    "local f = function()\n  return 1\nend\ng(function()\n  return 2\nend)\n")
  lays("if x then\nlocal f = function()\nreturn 1\nend\nend\n",
    "if x then\n  local f = function()\n    return 1\n  end\nend\n")
end

local function test_a_closer_stands_level_with_the_construct_it_closes()
  lays("if x then\n  return 1\nelseif y then\n  return 2\nelse\n  return 3\nend\n",
    "if x then\n  return 1\nelseif y then\n  return 2\nelse\n  return 3\nend\n")
  lays("  if a then\nb()\n   elseif c then\nd()\n  else\ne()\n  end\n",
    "if a then\n  b()\nelseif c then\n  d()\nelse\n  e()\nend\n")
  lays("repeat\nx()\n  until y\n", "repeat\n  x()\nuntil y\n")
  lays("while a do\nfor i = 1, 2 do\nfor k, v in t do\nx()\nend\nend\nend\n",
    "while a do\n  for i = 1, 2 do\n    for k, v in t do\n      x()\n    end\n  end\nend\n")
end

local function test_a_function_in_a_block_is_indented_with_it()
  lays("if x then\nlocal function m()\nend\nend\n", "if x then\n  local function m()\n  end\nend\n")
  lays("local  function g(a:integer):integer\n      return a\nend\n",
    "local function g(a: integer): integer\n  return a\nend\n")
  lays("local M = {}\nfunction M.go(self: any)\nreturn 1\nend\n",
    "local M = {}\nfunction M.go(self: any)\n  return 1\nend\n")
end

local function test_the_arms_of_a_match_are_laid_out_like_the_arms_of_an_if()
  lays("match f(x) do\n| (true, v) then\nprint(v)\n| (false, _) then\nprint(1)\nend\n",
    "match f(x) do\n| (true, v) then\n  print(v)\n| (false, _) then\n  print(1)\nend\n")
  lays("if y then\n  match f(x) do\n      | (true, v) then print(v)\n   | (false, _) then\n  print(1)\n  end\nend\n",
    "if y then\n  match f(x) do\n  | (true, v) then print(v)\n  | (false, _) then\n    print(1)\n  end\nend\n")
end

local function test_the_members_of_a_record_a_class_an_interface_and_an_enum_are_indented()
  lays("local record R\nx: integer\n--- the name\nname?: string\nend\n",
    "local record R\n  x: integer\n  --- the name\n  name?: string\nend\n")
  lays("local enum E\n\"a\"\n\"b\"\nend\n", "local enum E\n  \"a\"\n  \"b\"\nend\n")
  lays("local interface I\nx: integer\nend\n", "local interface I\n  x: integer\nend\n")
  lays("local class C\nx: integer\nfunction get(self): integer\nreturn self.x\nend\nend\n",
    "local class C\n  x: integer\n  function get(self): integer\n    return self.x\n  end\nend\n")
  lays("local record Outer\nrecord Inner\nx: integer\nend\ny: Inner\nend\n",
    "local record Outer\n  record Inner\n    x: integer\n  end\n  y: Inner\nend\n")
  lays("do\nlocal record R\nx: integer\nend\nend\n", "do\n  local record R\n    x: integer\n  end\nend\n")
end

local function test_a_one_line_block_is_left_on_its_line()
  lays("if x then return 1 end\n", "if x then return 1 end\n")
  lays("if x then   return 1\n   end\n", "if x then return 1\nend\n")
  lays("local function h() end\n", "local function h() end\n")
  lays("local record R x: integer end\n", "local record R x: integer end\n")
end

local function test_a_long_string_keeps_its_bytes_inside_an_indented_block()
  lays("if x then\nlocal s = [[\n  a\n b]]\n  y = [==[\n]==]\nend\n",
    "if x then\n  local s = [[\n  a\n b]]\n  y = [==[\n]==]\nend\n")
  lays("do\nx = f([[a\r\n  b]],\n'c\\\r\nd')\nend\n", "do\n  x = f([[a\r\n  b]],\n  'c\\\r\nd')\nend\n")
  lays("do\nlocal t = '--[[ not a comment ]]' .. \"-- nor this\"\nend\n",
    "do\n  local t = '--[[ not a comment ]]' .. \"-- nor this\"\nend\n")
end

local function test_a_run_of_blank_lines_is_one_and_the_ends_of_the_file_have_none()
  lays("a=1\r\nb=2\r\n\r\n\r\n\r\nc=3\n", "a = 1\nb = 2\n\nc = 3\n")
  lays("if x then\n\n\n  y()\n\n\n  z()\n\n\nend\n\n\n\nw()\n", "if x then\n\n  y()\n\n  z()\n\nend\n\nw()\n")
  lays("do\n   \n \t\n x()\nend\n", "do\n\n  x()\nend\n")
  lays("\n\n\nx=1\n\n\n", "x = 1\n")
  lays("x=1", "x = 1\n")
  lays("x=1\n-- end\n\n\n", "x = 1\n-- end\n")
  lays("record_ = 1\n\n\n-- c\n\n\ny = 2\n", "record_ = 1\n\n-- c\n\ny = 2\n")
end

local function test_a_comment_after_code_stays_on_its_line()
  lays("x=1   -- why\n", "x = 1 -- why\n")
  lays("if x then -- a\n  y() -- b\nend -- c\n", "if x then -- a\n  y() -- b\nend -- c\n")
  lays("local function f() -- doc\n      return 1   --one\n   end--two\n",
    "local function f() -- doc\n  return 1 --one\nend --two\n")
  lays("local a = 1\nprint(a) -- why", "local a = 1\nprint(a) -- why\n")
  lays("local q = [[\nhi\n]] -- tail", "local q = [[\nhi\n]] -- tail\n")
end

local function test_a_comment_on_its_own_line_takes_the_indentation_of_the_code_after_it()
  lays("if true then\n-- q\nprint(1)\nend\n", "if true then\n  -- q\n  print(1)\nend\n")
  lays("      -- a\n      -- b\n      x = 1\n", "-- a\n-- b\nx = 1\n")
  lays("local function g()\n--- doc\nlocal function h() end\n    -- 2\n    return h\nend\n",
    "local function g()\n  --- doc\n  local function h() end\n  -- 2\n  return h\nend\n")
  lays("-- hello\n--#region\nprint(1)\n--#endregion\n", "-- hello\n--#region\nprint(1)\n--#endregion\n")
end

local function test_a_tab_indented_source_is_laid_out_with_spaces()
  lays("if x then\n\t-- c\n\ty() -- t\n\tif z then\n\t\tw()\n\t\t-- d\n\tend\n\t-- e\nend\n",
    "if x then\n  -- c\n  y() -- t\n  if z then\n    w()\n    -- d\n  end\n  -- e\nend\n")
end

local function test_a_comment_not_lined_up_with_the_code_after_it_keeps_its_column_moved_with_the_code()
  lays("x = 1\n      -- apart\ny = 2\n", "x = 1\n      -- apart\ny = 2\n")
  lays("if x then\n      -- apart\n      y()\nend\n", "if x then\n  -- apart\n  y()\nend\n")
  lays("if x then\n          -- apart\n      y()\nend\n", "if x then\n      -- apart\n  y()\nend\n")
  lays("if x then\n   -- near\n    y()\nend\n", "if x then\n -- near\n  y()\nend\n")
  lays("      if x then\n          -- apart\n          y()\n      end\n", "if x then\n  -- apart\n  y()\nend\n")
end

local function test_a_comment_before_a_closer_moves_as_the_last_statement_of_the_body_moved()
  lays("if x then\n      y()\n      -- c\n    end\n", "if x then\n  y()\n  -- c\nend\n")
  lays("if x then\n  y()\n-- c\nend\n", "if x then\n  y()\n-- c\nend\n")
  lays("if x then\n    y()\n    -- c\nelseif z then\n  w()\n    -- d\nelse\n  v()\n      -- e\nend\n",
    "if x then\n  y()\n  -- c\nelseif z then\n  w()\n    -- d\nelse\n  v()\n      -- e\nend\n")
  lays("repeat\n  x()\n  -- c\nuntil y\n", "repeat\n  x()\n  -- c\nuntil y\n")
  lays("match f() do\n| (true) then\n  x()\n  -- c\n| (false) then\n  y()\nend\n",
    "match f() do\n| (true) then\n  x()\n  -- c\n| (false) then\n  y()\nend\n")
  lays("local record R\n  x: integer\n  -- c\nend\n", "local record R\n  x: integer\n  -- c\nend\n")
  lays("  local record R\n      x: integer\n      -- c\n  end\n", "local record R\n  x: integer\n  -- c\nend\n")
end

local function test_a_comment_in_an_empty_body_moves_as_the_line_that_opened_it()
  lays("if x then\n  -- c\nend\n", "if x then\n  -- c\nend\n")
  lays("    if x then\n      -- c\n    end\n", "if x then\n  -- c\nend\n")
  lays("    if x then\n  -- c\n    end\n", "if x then\n-- c\nend\n")
  lays("do\n  do\n-- c\n  end\nend\n", "do\n  do\n-- c\n  end\nend\n")
  lays("local function f() -- a\n    -- c\n end\n", "local function f() -- a\n    -- c\nend\n")
  lays("local record R\n  -- c\nend\n", "local record R\n  -- c\nend\n")
end

local function test_a_comment_at_the_end_of_the_file_moves_as_the_last_statement()
  lays("local a = 1\nprint(a)\n-- the end", "local a = 1\nprint(a)\n-- the end\n")
  lays("local a = 1\nprint(a)\n-- one\n-- two", "local a = 1\nprint(a)\n-- one\n-- two\n")
  lays("  local a = 1\n  print(a)\n  -- one\n  -- two", "local a = 1\nprint(a)\n-- one\n-- two\n")
  lays("if x then\n  y()\nend\n  -- tail\n", "if x then\n  y()\nend\n  -- tail\n")
  lays("-- only", "-- only\n")
  lays("   -- only\n\n   -- more\n", "   -- only\n\n   -- more\n")
  lays("local a = 1\nprint(a)\n--", "local a = 1\nprint(a)\n--\n")
  lays("local a = 1\nprint(a)\n--[", "local a = 1\nprint(a)\n--[\n")
end

local function test_a_comment_is_written_as_it_is_even_to_its_trailing_whitespace()
  lays("x = 1 -- why   \n", "x = 1 -- why   \n")
  lays("if x then\n  -- a \t\n  y()\nend\n", "if x then\n  -- a \t\n  y()\nend\n")
  lays("x = 1 --\t\n", "x = 1 --\t\n")
end

local function test_a_hashbang_line_is_kept_and_the_code_after_it_is_laid_out()
  lays("#!/usr/bin/env cosmic\nprint(1)\n", "#!/usr/bin/env cosmic\nprint(1)\n")
  lays("#!/usr/bin/env cosmic\n", "#!/usr/bin/env cosmic\n")
  lays("#!/bin/cosmic\n\n\n  if x then\ny()\n   end", "#!/bin/cosmic\n\nif x then\n  y()\nend\n")
end

local function test_a_whole_file_is_laid_out()
  lays(lines({
    "-- a module",
    "local M = {}",
    "",
    "",
    "--- the function",
    "function M.f(a)",
    "      if a then   -- yes",
    "        return {1,2}",
    "         -- else",
    "      else",
    "      return nil",
    "      end",
    "end",
    "",
    "return M",
  }), lines({
    "-- a module",
    "local M = {}",
    "",
    "--- the function",
    "function M.f(a)",
    "  if a then -- yes",
    "    return { 1, 2 }",
    "     -- else",
    "  else",
    "    return nil",
    "  end",
    "end",
    "",
    "return M",
  }))
end

local function test_a_source_with_a_long_comment_or_a_cut_form_is_refused()
  Check.refuses("x = 1\n--[[c]] y = 2\n")
  Check.refuses("x = 1;\n")
  Check.refuses("if x then\n")
end
