--- What holds of [`build.fix.layout`] for any source, over tiny laid-out sources that the test spoils in ways that
--- keep their meaning: the whitespace within a line, the indentation of each line, and the line breaks themselves.
---
--- - Nothing is added, removed or changed: the tokens and comments (kind and text, a long string's bytes and a
---   comment's trailing whitespace among them), the tree and the line breaks that are there are the same after.
--- - Laying out what is laid out changes nothing.
--- - The whitespace outside a type does not reach the result: the spaces and tabs between tokens, the indentation
---   of a line (a comment on its own line lined up with the code after it), and a break moved to another gap leave a
---   source that lays out as the one with the break moved would. A line of a type is the exception: the author's
---   spacing of a type includes the columns of its lines, relative to the line that holds its first token.
--- A comment on a line of its own that is not lined up with the code after it keeps its column, so what it was
--- written at does reach the result; [`build.fix.layout_blocks_test`] holds that.
--- Indentation is whitespace to a Teal source, as it is to Lua, but for the bytes of a long string; the cases
--- here put one inside an indented block.
local Check = require("build.fix.layout_check")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "build/fix/trivia.tl", letters = "r" }, { path = "build/fix/roles.tl", letters = "r" },
    { path = "build/fix/blocks.tl", letters = "r" }, { path = "build/fix/layout.tl", letters = "r" },
    { path = "build/fix/layout_check.tl", letters = "r" }, { path = "build/fix/near.tl", letters = "r" },
    { path = "build/fix/continuation.tl", letters = "r" },
    { path = "build/fix/init.tl", letters = "r" }, { path = "build/codec.tl", letters = "r" },
    { path = "build/paths.tl", letters = "r" }, { path = "lang/ast_dump.tl", letters = "r" },
    { path = "lang/literals.tl", letters = "r" }, { path = "lang/flow.tl", letters = "r" },
    { path = "build/lsp/session_fixture.tl", letters = "r" }, { path = "cosmic/string.tl", letters = "r" },
  },
}

local laid, lays = Check.laid, Check.lays

--- Sources already laid out, each of which must lay out as itself, and from which the next tests spoil the
--- whitespace. A comment on a line of its own stands level with the code after it.
local CANON <const>: {string} = {
  "local x <const>, y <close>: integer, string = 1, \"x\"\n",
  "local s = x + 1 .. \"a\" - -y\n",
  "local t = { a = 1, [\"b\"] = 2, [ [[k]] ] = 3, {}, { 1, { 2 } } }\n",
  "x = -(a + b) * #t + (not c and d)\n",
  "local r = t:m(1, 2).k[3](f()) + g(...)\n",
  "local function k<T, U>(t: T, u?: U, ...: any): T, U return t, u end\n",
  "for i = 1, 10, 2 do print(i) end\nfor k, v in pairs(t) do print(k) end\n",
  "while a > 0 do a = a - 1 end\nrepeat a = 1 until a > 0\n",
  "local v = if a then b elseif c then d else e end\n",
  "local w = t as {string:any} -- kept\nlocal u = t is string\n",
  "-- own line\nx = f(function(a, b) return a end, {}) -- trail\n\ny = 1\n",
  "local record R\n  mut items: {string}\n  name?: string\n  [\"a b\"]?: T\nend\n",
  "if x then\n  y() -- t\nelseif z then\n  -- c\n  w()\nelse\n  v()\nend\n",
  "-- head\nlocal function f(a)\n  --- doc\n  local b = a\n\n  return b -- r\nend\n-- tail\n",
  "repeat\n  x()\n  do\n    y()\n  end\nuntil z\n",
  "match f(x) do\n| (true, v) then\n  print(v)\n| (false, _) then\n  print(1)\nend\n",
  "local class C\n  x: integer\n\n  function get(self): integer\n    return self.x\n  end\nend\n",
  "local enum E\n  \"a\"\n  \"b\"\nend\n",
  "local record Outer\n  record Inner\n    x: integer\n  end\n  y: Inner\nend\n",
  "f(function()\n  return 1\nend)\n",
  "if x then\n  local s = [[\n  a\n b]]\n  y = [==[\n]==]\nend\n",
  "do\n  do\n    -- c\n    z()\n  end\nend\n",
  "#!/bin/cosmic\n\nx = 1\n",
  "local t = {\n  a = 1,\n  b = f(x,\n    y),\n  c = {\n    1,\n  },\n}\n",
  "local function h(a: integer,\n                 b: string)\n  return a\nend\n",
  "if a and\n    b then\n  f()\nelseif c or\n    d then\n  g()\nend\n",
  "run(a,\n  function(v)\n    return v\n  end)\n",
  "local x = a and\n  b -- c\nlocal w = (a ==\n  b)\n",
  "local y: {\n  string\n} = {}\n",
  "local class C\n  function add(self, a,\n               b): integer\n    return a +\n      b\n  end\nend\n",
  "match f(x) do\n| (true,\n    v) then\n  print(v)\nend\n",
  "local function f(\n    a: integer,\n    b: integer): integer\n  return a\nend\n",
  "local u = {\n  -- c\n  1,\n  2, -- d\n  {\n    3,\n  },\n}\n",
  "Test.policy{ grants = { { path = \"x\", letters = \"r\" } } }\n",
  "local type Input<P,Q> = Types.Input<P,Q>\nlocal function g<T ,U>(a: T) end\n",
  "local x = a or -- t\n  -- own\n  b\n",
  "local x = a\n  -- own\n  or -- t\n  b\n",
  "local x = a -- one\n  or -- two\n  b\n",
  "local x = a and\n  b or\n  c\nlocal y = {\n  p ..\n    q, -- r\n}\n",
  "local t = {\n  x as function(): integer\n}\n",
  "local function f(a: {\n    string\n  }): integer\n  return 1\nend\n",
}

local function test_laid_out_sources_are_fixed_points()
  for _, source in ipairs(CANON) do
    lays(source, source)
  end
end

local function test_the_whitespace_an_author_wrote_between_tokens_does_not_reach_the_result()
  for _, source in ipairs(CANON) do
    for seed = 1, 6 do
      lays(Check.respaced(source, seed), source)
    end
  end
end

local function test_the_indentation_an_author_wrote_does_not_reach_the_result()
  local moved = 0
  for _, source in ipairs(CANON) do
    for seed = 1, 6 do
      local spoilt = Check.reindented(source, seed)
      if spoilt ~= source then
        moved = moved + 1
      end
      lays(spoilt, source)
    end
  end
  assert(moved > 20, "the indentation was drawn again in only " .. tostring(moved) .. " sources")
end

local function test_a_source_with_its_breaks_moved_is_laid_out_with_them_where_they_are()
  local moved = 0
  for _, source in ipairs(CANON) do
    for seed = 1, 8 do
      local spoilt = Check.rebroken(source, seed)
      if Check.breaks_of(spoilt) ~= Check.breaks_of(source) then
        moved = moved + 1
      end
      -- It keeps the tokens, comments, tree and breaks it has (`laid` holds it to that) and is a fixed point; and
      -- the indentation it was written with leaves the result as it was.
      local got = laid(spoilt)
      lays(Check.reindented(spoilt, seed), got)
      lays(Check.respaced(spoilt, seed), got)
    end
  end
  assert(moved > 20, "the breaks were moved in only " .. tostring(moved) .. " sources")
end

local function test_a_long_string_and_the_text_of_a_comment_are_never_touched_by_the_indentation_around_them()
  local source = "if a then\n  local s = [[\n\t  x  \n]]  .. 'q'\n  -- see [[ this ]] and --[==[ that\n" ..
    "  y = '--[[ z ]]'\nend\n"
  local want = "if a then\n  local s = [[\n\t  x  \n]] .. 'q'\n  -- see [[ this ]] and --[==[ that\n" ..
    "  y = '--[[ z ]]'\nend\n"
  for seed = 1, 6 do
    lays(Check.reindented(source, seed), want)
  end
  local nested = "do\n  do\n    do\n      s = [=[\n  ]]\n]=]\n    end\n  end\nend\n"
  assert(laid(nested):find("s = [=[\n  ]]\n]=]\n", 1, true) ~= nil, laid(nested))
end

--- The number of lines of `text` that hold something.
local function lines_of(text: string): integer
  local count = 0
  for line in text:gmatch("[^\r\n]+") do
    if line:find("%S") ~= nil then
      count = count + 1
    end
  end
  return count
end

--- Modules of the tree: they hold every construct a file has.
local MODULES <const>: {string} = {
  "build/fix/trivia.tl", "build/fix/roles.tl", "build/fix/blocks.tl", "build/fix/layout.tl",
  "build/fix/layout_check.tl", "build/fix/near.tl", "build/fix/init.tl", "build/codec.tl", "build/paths.tl",
  "lang/ast_dump.tl", "lang/literals.tl", "lang/flow.tl", "build/lsp/session_fixture.tl", "cosmic/string.tl",
  "build/fix/continuation.tl",
}

local function test_real_modules_keep_their_tokens_comments_and_tree_and_lay_out_to_a_fixed_point()
  for _, path in ipairs(MODULES) do
    local source = assert(Fs.read(path))
    local first = laid(source)
    assert(lines_of(first) == lines_of(source), path .. " gained or lost a line")
  end
end
