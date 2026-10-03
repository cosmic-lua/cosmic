--- How `cosmic fix` indents a line that continues a statement
--- ([`build.fix.ctx`]), checked against the exact text expected and
--- through the whole verb, so each case is reparsed and compared for
--- meaning too.

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

local function test_a_bracket_indents_its_entries_two_past_its_line()
  writes("local t = {\n      a = 1,\n   b = 2,\n    }\n", "local t = {\n  a = 1,\n  b = 2,\n}\n")
  writes("local s = f(a,\n            b)\n", "local s = f(a,\n  b)\n")
  writes("f({\n    x = 1,\n  })\n", "f({\n  x = 1,\n})\n")
end

--- Brackets opened on one line count once; one opened on a later line
--- indents from that line.
local function test_brackets_nest_by_the_lines_they_open_on()
  writes("local s = f(a, g(b,\n c))\n", "local s = f(a, g(b,\n  c))\n")
  writes("local s = f(a,\n  g(b,\n c))\n", "local s = f(a,\n  g(b,\n    c))\n")
end

--- A line continuing an entry, not starting the next, goes two further;
--- in a parenthesis or an index there is only one entry to continue.
local function test_a_continued_entry_goes_two_further()
  writes("local t = {\n  b = x ..\n  y,\n}\n", "local t = {\n  b = x ..\n    y,\n}\n")
  writes("f(\"a\" ..\n\"b\", c)\n", "f(\"a\" ..\n    \"b\", c)\n")
  writes("local w = (a ..\nb)\n", "local w = (a ..\n  b)\n")
end

--- Outside any bracket a statement continues two columns in, and a
--- block's header four, apart from the body two below it.
local function test_a_statement_and_a_header_continue()
  writes("local v = \"x\" ..\n         \"y\"\n", "local v = \"x\" ..\n  \"y\"\n")
  writes("if a and\n   b then\n  return\nend\n", "if a and\n    b then\n  return\nend\n")
  writes("while a and\nb do\n  f()\nend\n", "while a and\n    b do\n  f()\nend\n")
  writes("if f(a,\n b) then\n  return\nend\n", "if f(a,\n    b) then\n  return\nend\n")
end

--- A parameter list whose first parameter follows its `(` lines the
--- rest up under it; one opening on a line of its own is a bracket of
--- the signature, a block's header.
local function test_parameters_line_up_under_the_first()
  writes("local function h(a: integer,\n   b: string)\nend\n",
    "local function h(a: integer,\n                 b: string)\nend\n")
  writes("local function h(\n      a: integer)\nend\n", "local function h(\n    a: integer)\nend\n")
end

--- A comment lined up with the code after it moves with that code; one
--- that is not keeps its place beside the statement.
local function test_a_lined_up_comment_moves_with_its_code()
  writes("local w = {\n        -- note\n        a = 1,\n}\n", "local w = {\n  -- note\n  a = 1,\n}\n")
end

--- A statement moved left onto a line of its own takes its continuation
--- lines to its own indentation, not to where it was.
local function test_a_moved_statement_indents_its_continuation()
  writes("f() local x = a\n  as integer\n", "f()\nlocal x = a\n  as integer\n")
end

--- A function's signature is a block's header: its lines are set apart
--- from the body, a return type alone on its line and parameters
--- opening on one alike.
local function test_a_signature_continues_four_in()
  writes("local function long(a: integer, b: integer):\n  integer\n  return a\nend\n",
    "local function long(a: integer, b: integer):\n    integer\n  return a\nend\n")
  writes("local function f(\n  a: integer,\n  b: integer): integer\n  return a\nend\n",
    "local function f(\n    a: integer,\n    b: integer): integer\n  return a\nend\n")
end

--- A `for` and an `elseif` header continue four in, and an index holds
--- one entry, continued two in.
local function test_headers_and_an_index_continue()
  writes("for k, v in\n pairs(t) do\n  f()\nend\n", "for k, v in\n    pairs(t) do\n  f()\nend\n")
  writes("if a then\n  f()\nelseif b and\n c then\n  g()\nend\n",
    "if a then\n  f()\nelseif b and\n    c then\n  g()\nend\n")
  writes("local y = t[a ..\n b]\n", "local y = t[a ..\n  b]\n")
end

--- A comment lined up with no code keeps its place beside the
--- statement, and one beside code behind a long comment's `]]` is not
--- lined up with it: that code opens no line.
local function test_a_comment_not_lined_up_keeps_its_place()
  writes("local w = {\n  a = 1,\n      -- odd\n  b = 2,\n}\n", "local w = {\n  a = 1,\n      -- odd\n  b = 2,\n}\n")
  writes("local function f()\n    local t = {\n      a =\n          -- c\n      --[[ d\n     ]] 1,\n    }\nend\n",
    "local function f()\n  local t = {\n    a =\n        -- c\n    --[[ d\n     ]] 1,\n  }\nend\n")
end

--- The comments before a function literal's `end` move as the literal
--- moved: with its body, or lined up with the `end` itself.
local function test_comments_before_a_literals_end_move_with_it()
  writes("local x = f(a,\n      function()\n        g()\n        -- trailing\n      end)\n",
    "local x = f(a,\n  function()\n    g()\n    -- trailing\n  end)\n")
  writes("f(a,\n      function()\n        g()\n      -- c\n      end)\n",
    "f(a,\n  function()\n    g()\n  -- c\n  end)\n")
end
