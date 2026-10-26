--- [`build.fix.layout`] over tiny sources whose lines continue a statement: the indentation of a line from the
--- brackets open where it starts, a table's trailing comma, a function written on a continuation line, a binary
--- operator that begins a line, an `if` expression and a type that spans lines. The cases are the previous formatter's (its
--- continuation, render and breaks tests), checked against the text it wrote. Every case also goes through
--- [`build.fix.layout_check`]'s properties: no token or comment changes, the tree is the same, the breaks are the
--- source's but for the operators that move, and laying out what is laid out changes nothing.
local Check = require("build.fix.layout_check")
local Test = require("cosmic.test")

Test.policy{}

local lays = Check.lays

--- `text` joined by line breaks, with one at the end.
local function lines(text: {string}): string
  return table.concat(text, "\n") .. "\n"
end

local function test_a_bracket_indents_its_entries_two_past_its_line()
  lays("local t = {\n      a = 1,\n   b = 2,\n    }\n", "local t = {\n  a = 1,\n  b = 2,\n}\n")
  lays("local s = f(a,\n            b)\n", "local s = f(a,\n  b)\n")
  lays("f({\n    x = 1,\n  })\n", "f({\n  x = 1,\n})\n")
end

local function test_brackets_nest_by_the_lines_they_open_on()
  lays("local s = f(a, g(b,\n c))\n", "local s = f(a, g(b,\n  c))\n")
  lays("local s = f(a,\n  g(b,\n c))\n", "local s = f(a,\n  g(b,\n    c))\n")
end

local function test_a_continued_entry_goes_two_further_and_an_index_or_parenthesis_holds_one_entry()
  lays("local t = {\n  b = x ..\n  y,\n}\n", "local t = {\n  b = x ..\n    y,\n}\n")
  lays("f(\"a\" ..\n\"b\", c)\n", "f(\"a\" ..\n    \"b\", c)\n")
  lays("local w = (a ..\nb)\n", "local w = (a ..\n  b)\n")
  lays("local y = t[a ..\n b]\n", "local y = t[a ..\n  b]\n")
  lays("local y = t[\n  a ..\n b\n]\n", "local y = t[\n  a ..\n  b\n]\n")
end

local function test_a_closing_bracket_that_begins_a_line_is_level_with_the_line_that_opened_it()
  lays("local t = {\n  1,\n      }\n", "local t = {\n  1,\n}\n")
  lays("f(\n    a,\n        b\n  )\n", "f(\n  a,\n  b\n)\n")
  lays("if f(\n  a\n  ) then\n  g()\nend\n", "if f(\n    a\n) then\n  g()\nend\n")
  lays("local u = {\n  {\n   1,\n        },\n}\n", "local u = {\n  {\n    1,\n  },\n}\n")
end

local function test_a_statement_and_a_header_continue()
  lays("local v = \"x\" ..\n         \"y\"\n", "local v = \"x\" ..\n  \"y\"\n")
  lays("if a and\n   b then\n  return\nend\n", "if a and\n    b then\n  return\nend\n")
  lays("while a and\nb do\n  f()\nend\n", "while a and\n    b do\n  f()\nend\n")
  lays("if f(a,\n b) then\n  return\nend\n", "if f(a,\n    b) then\n  return\nend\n")
  lays("do\n  local v = 1 +\n 2\nend\n", "do\n  local v = 1 +\n    2\nend\n")
  lays("do\n  if a and\n   b then\n    x()\n  end\nend\n", "do\n  if a and\n      b then\n    x()\n  end\nend\n")
end

local function test_a_for_an_elseif_an_until_and_a_match_header_continue_four_in()
  lays("for k, v in\n pairs(t) do\n  f()\nend\n", "for k, v in\n    pairs(t) do\n  f()\nend\n")
  lays("for i = 1,\n 2 do\n  f()\nend\n", "for i = 1,\n    2 do\n  f()\nend\n")
  lays("if a then\n  f()\nelseif b and\n c then\n  g()\nend\n", "if a then\n  f()\nelseif b and\n    c then\n  g()\nend\n")
  lays("repeat\n  f()\nuntil a and\n b\n", "repeat\n  f()\nuntil a and\n    b\n")
  lays("if a\nthen\n  f()\nend\n", "if a\n    then\n  f()\nend\n")
  lays("match f(a,\n b) do\n| (true) then\n  g()\nend\n", "match f(a,\n    b) do\n| (true) then\n  g()\nend\n")
end

local function test_parameters_line_up_under_the_first()
  lays("local function h(a: integer,\n   b: string)\nend\n", "local function h(a: integer,\n                 b: string)\nend\n")
  lays("local function h(\n      a: integer)\nend\n", "local function h(\n    a: integer)\nend\n")
  lays("function M.h(self, a,\n  b)\nend\n", "function M.h(self, a,\n             b)\nend\n")
end

local function test_a_signature_continues_four_in()
  lays("local function long(a: integer, b: integer):\n  integer\n  return a\nend\n",
    "local function long(a: integer, b: integer):\n    integer\n  return a\nend\n")
  lays("local function f(\n  a: integer,\n  b: integer): integer\n  return a\nend\n",
    "local function f(\n    a: integer,\n    b: integer): integer\n  return a\nend\n")
  lays("local g = function(a,\n  b)\n  return a\nend\n", "local g = function(a,\n                   b)\n  return a\nend\n")
end

local function test_a_parameter_list_inside_a_body_is_aligned_from_where_it_is_written()
  lays("do\n  local function h(a,\n b)\n  end\nend\n", "do\n  local function h(a,\n                   b)\n  end\nend\n")
end

local function test_a_lined_up_comment_moves_with_its_code_and_another_keeps_its_place_beside_the_statement()
  lays("local w = {\n        -- note\n        a = 1,\n}\n", "local w = {\n  -- note\n  a = 1,\n}\n")
  lays("local w = {\n  a = 1,\n      -- odd\n  b = 2,\n}\n", "local w = {\n  a = 1,\n      -- odd\n  b = 2,\n}\n")
  lays("local w = {\n        a = 1,\n      -- odd\n        b = 2,\n}\n", "local w = {\n  a = 1,\n      -- odd\n  b = 2,\n}\n")
  lays("  local w = {\n          a = 1,\n          -- odd\n  }\n", "local w = {\n  a = 1,\n        -- odd\n}\n")
end

local function test_a_comment_before_a_closing_bracket_is_lined_up_with_it_or_keeps_its_place()
  lays("local t = {\n  1,\n  -- c\n}\n", "local t = {\n  1,\n  -- c\n}\n")
  lays("local t = {\n  1,\n-- c\n}\n", "local t = {\n  1,\n-- c\n}\n")
  lays("f(a,\n  b -- t\n  )\n", "f(a,\n  b -- t\n)\n")
end

local function test_a_function_literal_opens_its_body_from_the_line_it_is_written_on()
  lays(lines({
    "local ok = apply(",
    "  { 1, 2 },",
    "  function(v)",
    "      return v and",
    "        true",
    "  end",
    ")",
  }), lines({
    "local ok = apply(",
    "  { 1, 2 },",
    "  function(v)",
    "    return v and",
    "      true",
    "  end",
    ")",
  }))
  lays(lines({
    "local handlers = {",
    "  go = function(v)",
    "  return v",
    "end,",
    "}",
  }), lines({
    "local handlers = {",
    "  go = function(v)",
    "    return v",
    "  end,",
    "}",
  }))
  lays(lines({
    "local u = { 1,",
    "   function()",
    "  return 2",
    "  end }",
  }), lines({
    "local u = { 1,",
    "  function()",
    "    return 2",
    "  end }",
  }))
end

local function test_functions_nested_through_continuation_lines_are_indented_all_the_way_down_and_back()
  lays(lines({
    "local deep = outer(",
    "  function()",
    "  return inner(",
    "    function()",
    "    return 1",
    "  end",
    "  )",
    "end",
    ")",
  }), lines({
    "local deep = outer(",
    "  function()",
    "    return inner(",
    "      function()",
    "        return 1",
    "      end",
    "    )",
    "  end",
    ")",
  }))
end

local function test_a_statement_in_a_function_literal_continues_from_its_own_brackets()
  lays(lines({
    "run(a,",
    "  function()",
    "    local t = {",
    "    x = 1,",
    "    }",
    "    f(1,",
    "    2)",
    "  end)",
  }), lines({
    "run(a,",
    "  function()",
    "    local t = {",
    "      x = 1,",
    "    }",
    "    f(1,",
    "      2)",
    "  end)",
  }))
end

local function test_the_comments_before_a_literals_end_move_as_the_literal_moved()
  lays("local x = f(a,\n      function()\n        g()\n        -- trailing\n      end)\n",
    "local x = f(a,\n  function()\n    g()\n    -- trailing\n  end)\n")
  lays("f(a,\n      function()\n        g()\n      -- c\n      end)\n", "f(a,\n  function()\n    g()\n  -- c\n  end)\n")
  lays("f(a,\n      function()\n        -- c\n      end)\n", "f(a,\n  function()\n    -- c\n  end)\n")
end

local function test_a_comment_before_a_closer_moves_with_the_body()
  lays("f(function()\n        g()\n        -- c\n    end)\n", "f(function()\n  g()\n  -- c\nend)\n")
  lays("local function f()\n    g()\n    -- c\nend\n", "local function f()\n  g()\n  -- c\nend\n")
  lays("if a then\n      g()\n      -- c\nelse\n      h()\n      -- d\nend\n", "if a then\n  g()\n  -- c\nelse\n  h()\n  -- d\nend\n")
  lays("repeat\n    g()\n    -- c\nuntil x\n", "repeat\n  g()\n  -- c\nuntil x\n")
  lays("if a then\n      g()\n      -- c\nelseif b then\n      h()\nend\n", "if a then\n  g()\n  -- c\nelseif b then\n  h()\nend\n")
end

local function test_a_table_that_closes_on_a_line_of_its_own_ends_with_a_comma()
  lays("local t = {\n  1,\n  2\n}\n", "local t = {\n  1,\n  2,\n}\n")
  lays("local t = {\n  1,\n  2,\n}\n", "local t = {\n  1,\n  2,\n}\n")
  lays("local t = { 1,\n            2 }\n", "local t = { 1,\n  2 }\n")
  lays("local t = { 1,\n  2, }\n", "local t = { 1,\n  2 }\n")
  lays("local t = { 1, 2, }\n", "local t = { 1, 2 }\n")
  lays("local t = {\n  a = 1, -- one\n  b = 2 -- two\n}\n", "local t = {\n  a = 1, -- one\n  b = 2, -- two\n}\n")
  lays("local t = {\n  a = 1\n  -- last\n}\n", "local t = {\n  a = 1,\n  -- last\n}\n")
  lays("local t = {\n  {\n    1\n  }\n}\n", "local t = {\n  {\n    1,\n  },\n}\n")
  lays("f({\n  1\n}, {\n  2\n})\n", "f({\n  1,\n}, {\n  2,\n})\n")
  lays("local t = {\n}\n", "local t = {\n}\n")
end

local function test_a_comma_that_begins_its_line_is_left()
  lays("local t = {\n  1\n  , 2\n  ,\n}\n", "local t = {\n  1\n    , 2\n    ,\n}\n")
end

local function test_a_table_entry_that_ends_in_a_function_type_with_return_types_gets_no_comma()
  -- A `,` after it reads as another return type, and `}` after that is no type.
  lays("local t = {\n  x as function(): integer\n}\n", "local t = {\n  x as function(): integer\n}\n")
  lays("local t = {\n  y,\n  x as integer | function(): integer\n}\n", "local t = {\n  y,\n  x as integer | function(): integer\n}\n")
  lays("local t = {\n  x as function()\n}\n", "local t = {\n  x as function(),\n}\n")
  lays("local t = {\n  x as {string}\n}\n", "local t = {\n  x as {string},\n}\n")
  lays("local t = {\n  x as (function(): integer)\n}\n", "local t = {\n  x as (function(): integer),\n}\n")
  lays("local t = {\n  x is string\n}\n", "local t = {\n  x is string,\n}\n")
end

--- A return list in parentheses ends at its `)`, and a `,` after it is the table's.
local function test_a_table_entry_that_ends_in_a_parenthesised_return_list_gets_a_comma()
  lays("local t = {\n  x as function(): (A, B)\n}\n", "local t = {\n  x as function(): (A, B),\n}\n")
  lays("local t = {\n  x as function(): (string)\n}\n", "local t = {\n  x as function(): (string),\n}\n")
  lays("local t = {\n  x as function(): (true, R) | (false, E)\n}\n",
    "local t = {\n  x as function(): (true, R) | (false, E),\n}\n")
  lays("local t = {\n  x as function(): (A | B)\n}\n", "local t = {\n  x as function(): (A | B),\n}\n")
  lays("local t = {\n  x as function(): (A) | B\n}\n", "local t = {\n  x as function(): (A) | B,\n}\n")
  lays("local t = {\n  x as function(): A, B\n}\n", "local t = {\n  x as function(): A, B\n}\n")
end

local function test_an_operator_that_begins_a_line_moves_to_the_line_before_and_its_operand_takes_the_line()
  lays("local x = a\n  and b\n", "local x = a and\n  b\n")
  lays("local s = a\n  .. b\n  .. c\n", "local s = a ..\n  b ..\n  c\n")
  lays("if p ~= nil and f(p)\n   and g(p) then\n  return\nend\n", "if p ~= nil and f(p) and\n    g(p) then\n  return\nend\n")
  lays("local w = (a\n  == b)\n", "local w = (a ==\n  b)\n")
  lays("local s = 1\n  .. x\n", "local s = 1 ..\n  x\n")
end

local function test_a_moved_operator_goes_ahead_of_the_comments_the_line_before_ends_in()
  lays("local x = a -- why\n  or b\n", "local x = a or -- why\n  b\n")
  lays("local x = a\n  -- why\n  or b\n", "local x = a or\n  -- why\n  b\n")
  lays("local x = a -- one\n  -- two\n  or b\n", "local x = a or -- one\n  -- two\n  b\n")
  lays("local x = a\n  or -- why\n  b\n", "local x = a or -- why\n  b\n")
end

local function test_an_operator_alone_on_its_line_takes_the_line()
  lays("local x = a\n  and\n  b\n", "local x = a and\n  b\n")
  lays("local x = a\n  ..\n  -- c\n  b\n", "local x = a ..\n  -- c\n  b\n")
end

local function test_operators_not_beginning_a_line_a_unary_one_and_a_cast_are_left()
  lays("local x = a and\n  b\n", "local x = a and\n  b\n")
  lays("local x = a and\n  not b\n", "local x = a and\n  not b\n")
  lays("local x = f()\n  as integer\n", "local x = f()\n  as integer\n")
  lays("local x = f()\n  is integer\n", "local x = f()\n  is integer\n")
  lays("local x = a\n  - -b\n", "local x = a -\n  -b\n")
end

local function test_an_operator_is_left_when_a_comment_ends_its_line_and_another_lies_before_it_or_a_blank_line_is_before_it()
  lays("local x = a -- one\n  or -- two\n  b\n", "local x = a -- one\n  or -- two\n  b\n")
  lays("local x = a\n  -- own\n  or -- two\n  b\n", "local x = a\n  -- own\n  or -- two\n  b\n")
  lays("local x = a\n\n  or b\n", "local x = a\n\n  or b\n")
end

local function test_moved_operators_nest_with_the_brackets_around_them()
  lays("f(a\n  and b,\n  c)\n", "f(a and\n    b,\n  c)\n")
  lays("local t = {\n  a = x\n  or y,\n}\n", "local t = {\n  a = x or\n    y,\n}\n")
end

local function test_a_function_literal_as_the_operand_of_a_moved_operator_is_opened_from_its_line()
  lays("local f = a\n  or function()\n  return 1\nend\n", "local f = a or\n  function()\n    return 1\n  end\n")
end

--- The line that holds a type or an empty function is the line the operand takes, not the line the operator that
--- moved was on: the operator's own column says nothing of how far that line moved.
local function test_what_is_measured_by_a_line_is_measured_by_the_line_after_an_operator_moved()
  lays("local f = x\n  .. g(a as {\n    string\n  })\n", "local f = x ..\n  g(a as {\n    string\n  })\n")
  lays("local f = a\n  or function()\n  -- c\nend\n", "local f = a or\n  function()\n  -- c\n  end\n")
  lays("local f = a\n  or function()\n        -- c\n      end\n", "local f = a or\n  function()\n        -- c\n  end\n")
end

--- Each case lays out differently if the thing it names is measured another way.
local function test_the_shift_of_a_comment_in_an_empty_function_is_that_of_the_line_and_not_of_the_function()
  lays("local   f   =   function()\n        -- c\nend\n", "local f = function()\n        -- c\nend\n")
end

local function test_a_function_body_in_a_header_is_laid_out_as_a_body_and_not_as_the_header()
  lays("if f(function()\n  x = a +\n b\n end) then\n  g()\nend\n", "if f(function()\n  x = a +\n    b\nend) then\n  g()\nend\n")
end

local function test_a_line_after_a_long_string_is_measured_from_its_own_bytes()
  lays("do\n      x = [[a\n]] .. f(a as {\n         string\n      })\nend\n",
    "do\n  x = [[a\n]] .. f(a as {\n     string\n  })\nend\n")
end

local function test_a_signature_apart_from_the_function_it_names_continues_four_in()
  lays("local function\nf()\nend\n", "local function\n    f()\nend\n")
end

local function test_the_indentation_of_the_line_a_long_string_ends_on_is_counted_in_bytes()
  lays("x = f([[a\n\tb]], g(\n1))\n", "x = f([[a\n\tb]], g(\n   1))\n")
  lays("x = f([[a\n  b]], g(\n1))\n", "x = f([[a\n  b]], g(\n    1))\n")
end

local function test_a_type_that_spans_lines_moves_with_the_line_that_holds_its_first_token()
  lays("    local t: {\n        string\n    } = {}\n", "local t: {\n    string\n} = {}\n")
  lays("do\n      local t: {\n        string\n      } = {}\nend\n", "do\n  local t: {\n    string\n  } = {}\nend\n")
  lays("local class C\n      f: {\n          string\n      }\nend\n", "local class C\n  f: {\n      string\n  }\nend\n")
  -- A record's body is the author's.
  lays("local record R\n      f: {\n          string\n      }\nend\n", "local record R\n      f: {\n          string\n      }\nend\n")
end

--- The lines of a type move as the statement that holds the type moved, not as the line the type begins on.
local function test_a_type_on_a_continuation_line_moves_with_its_statement()
  lays("f(a,\n  b as {\n     string\n  })\n", "f(a,\n  b as {\n     string\n  })\n")
  lays("f(a,\n        b as {\n             string\n        })\n", "f(a,\n  b as {\n             string\n        })\n")
  lays("do\n      f(a,\n        b as {\n             string\n        })\nend\n",
    "do\n  f(a,\n    b as {\n         string\n    })\nend\n")
end

local function test_a_type_alone_on_its_line_after_a_colon_is_a_continuation()
  lays("local x:\n  integer = 1\n", "local x:\n  integer = 1\n")
  lays("local x:\ninteger = 1\n", "local x:\n  integer = 1\n")
  lays("local function f(a:\ninteger)\nend\n", "local function f(a:\n                   integer)\nend\n")
end

local function test_an_if_expression_is_a_bracket_whose_elseif_else_and_end_continue_its_line()
  lays("local v = if a then\n  b\nelseif c then\n  d\nelse\n  e\nend\n",
    "local v = if a then\n  b\n  elseif c then\n  d\n  else\n  e\n  end\n")
  lays("local v = if a then\n      b\n        elseif c then\n d\n   else\ne\n    end\n",
    "local v = if a then\n  b\n  elseif c then\n  d\n  else\n  e\n  end\n")
  lays("f(if a then\n  b\nelse\n  c\nend)\n", "f(if a then\n  b\n  else\n  c\n  end)\n")
  lays("f(\n      if a then\n b\n else\n c\n end,\n  2)\n", "f(\n  if a then\n    b\n    else\n    c\n    end,\n  2)\n")
  lays("do\n  local v = if a then\n    b +\n    c\n  else\n    d\n  end\nend\n",
    "do\n  local v = if a then\n    b +\n      c\n    else\n    d\n    end\nend\n")
  lays("local v = if a then b else c end\n", "local v = if a then b else c end\n")
  lays("if (if a then\n b\n else\n c\n end) then\n  f()\nend\n", "if (if a then\n    b\n  else\n    c\n  end) then\n  f()\nend\n")
end

--- The `then`, `elseif` and `else` of an `if` expression that begin a line are level with each other and with its
--- `end`, two columns in from the line of the `if`; so are the value of an arm and its condition when they begin a line,
--- as the tree writes `else` at the end of a line and the value below it.
local function test_the_then_of_an_if_expression_that_begins_a_line_is_level_with_its_else()
  lays("local x = if a\nthen b\nelse c end\n", "local x = if a\n  then b\n  else c end\n")
  lays("local x = if a\n    then b\n  elseif c\n then d\n else e\n end\n", "local x = if a\n  then b\n  elseif c\n  then d\n  else e\n  end\n")
  lays("do\n  local x = if a\n      then b\n      else c end\nend\n", "do\n  local x = if a\n    then b\n    else c end\nend\n")
  lays("f(if a\n    then b\n    else c end)\n", "f(if a\n  then b\n  else c end)\n")
  lays("local x = if a and\n b then\n  c\nelse\n  d\nend\n", "local x = if a and\n    b then\n  c\n  else\n  d\n  end\n")
  lays("local x = if a then b\n  elseif c then d\n  else e end\n", "local x = if a then b\n  elseif c then d\n  else e end\n")
  lays("local x = if a then b elseif\n      c then d else\n      e end\n", "local x = if a then b elseif\n  c then d else\n  e end\n")
end

local function test_a_match_arm_pattern_and_its_body_continue_like_those_of_an_if()
  lays("match f(x) do\n| (true,\n v) then\n  print(v)\nend\n", "match f(x) do\n| (true,\n    v) then\n  print(v)\nend\n")
  lays("if y then\n  match f(x,\n  z) do\n  | (true, v) then\n    print(v,\n    1)\n  end\nend\n",
    "if y then\n  match f(x,\n      z) do\n  | (true, v) then\n    print(v,\n      1)\n  end\nend\n")
end

local function test_the_methods_of_a_class_are_laid_out_like_functions_one_level_in()
  lays("local class C\n  x: integer\n  function add(self, a,\n  b): integer\n    return a +\n    b\n  end\nend\n",
    "local class C\n  x: integer\n  function add(self, a,\n               b): integer\n    return a +\n      b\n  end\nend\n")
  lays("local class C\n  function m(\n  self,\n  a)\n    run(function()\n      return 1\n    end)\n  end\nend\n",
    "local class C\n  function m(\n      self,\n      a)\n    run(function()\n      return 1\n    end)\n  end\nend\n")
end
