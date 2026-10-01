--- What `cosmic fix` writes, checked against the exact text expected,
--- one construct at a time.
---
--- The file leads with the `<const>`/`<close>` cases. A renderer that
--- re-emits source from a token stream, spacing tokens by a rule about
--- adjacency, writes `local x <const> = 5` as `local x < const > = 5`,
--- and only a test that compares against fixed text notices. Here the
--- attribute is a field on the variable's node and is written as one
--- unit attached to the name, so there is no spacing decision to get
--- wrong. The tree this tool renders uses neither attribute, so nothing
--- else exercises them.
---
--- The function-literal cases at the end have a second reason. A
--- literal is the only construct that opens a block inside an
--- expression, so its block can open off the grid its enclosing
--- statement sits on, on a continuation line as an argument or a table
--- value. Indenting its body from the statement instead writes the
--- body level with its own `function` keyword and the `end` two columns
--- further left, which at the top level is an `end` in column zero in
--- the middle of an argument list. That compiles and is a stable fixed
--- point, so only a golden string notices.
---
--- Every case goes through the whole verb, [`build.fix.source`], not the
--- renderer alone: that reparses what it wrote and compares the trees,
--- so a golden string here is checked for meaning as well as for text.

local ast = require("build.ast")
local fix = require("build.fix")
local render = require("build.fix.render")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Run the whole pipeline over `source`, asserting it succeeded.
--- @param source string
--- @return string What would be written
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

--- A fixture written a line at a time, closing newline and all, for the
--- cases whose whole point is which column each line starts in.
--- @param text {string} The lines, without their newlines
--- @return string
local function lines(text: {string}): string
  return table.concat(text, "\n") .. "\n"
end

--- A `<const>` is one unit against the name, with a single space in
--- front of it and none inside the angle brackets -- whatever spacing
--- the source used.
local function test_a_const_attribute_hugs_its_angle_brackets()
  writes("local x <const> = 5\n", "local x <const> = 5\n")
  writes("local    x    <const>    =    5\n", "local x <const> = 5\n")
end

--- The spelling a token-adjacency rule produces, fed back in: the
--- renderer reads the attribute off the node and writes the one correct
--- form.
local function test_a_spaced_out_attribute_is_written_back_closed_up()
  writes("local x < const > = 5\n", "local x <const> = 5\n")
  writes("local y < close > : integer = 6\n", "local y <close>: integer = 6\n")
end

--- The attribute comes before the type annotation. `local y: integer
--- <close> = 6` is not Teal, so there is one order to write.
local function test_a_close_attribute_precedes_the_type_annotation()
  writes("local y <close>: integer = 6\n", "local y <close>: integer = 6\n")
  local parsed, trouble = fix.source(built, "local y: integer <close> = 6\n",
                                     "wrong_order.tl")
  assert(parsed == nil, "the reversed order should not parse")
  assert(trouble ~= "", "a parse failure should say something")
end

--- Attributes on more than one name, with the type list Teal writes
--- after all of them.
local function test_attributes_on_several_names_in_one_declaration()
  writes("local a <const>, b <close>: integer, string = 1, \"x\"\n",
         "local a <const>, b <close>: integer, string = 1, \"x\"\n")
end

--- Spacing inside a line is the node's own: operators get one space on
--- each side, a comma gets one after it, `:` none before and one after.
local function test_operators_and_separators_are_spaced_from_the_node()
  writes("local s = x+1 ..  \"a\"\n", "local s = x + 1 .. \"a\"\n")
  writes("local z:integer=7\n", "local z: integer = 7\n")
  writes("local t = {1,2 ,  3}\n", "local t = { 1, 2, 3 }\n")
  writes("print( x )\n", "print(x)\n")
end

--- Unary operators keep their operand against them, except the worded
--- one, which needs its space to stay a word.
local function test_unary_operators()
  writes("local a = -x + not y + #z + ~w\n",
         "local a = -x + not y + #z + ~w\n")
end

--- The three ways a table literal writes a key, its entries standing
--- off its braces, and an empty one closed up.
local function test_table_literal_keys_and_brace_gaps()
  writes("local t = { a = 1, [\"b\"] = 2, 3 }\n",
         "local t = { a = 1, [\"b\"] = 2, 3 }\n")
  writes("local t = {a = 1, 2}\n", "local t = { a = 1, 2 }\n")
  writes("local t = {}\n", "local t = {}\n")
end

--- A table that closes on a line of its own gets a comma after its last
--- entry, so adding the next one changes one line; a table that closes
--- beside its last entry does not, because `a, b, }` reads as if
--- something is missing.
local function test_a_trailing_comma_follows_the_closing_brace()
  writes("local t = {\n  1,\n  2\n}\n", "local t = {\n  1,\n  2,\n}\n")
  writes("local t = {\n  1,\n  2,\n}\n", "local t = {\n  1,\n  2,\n}\n")
  writes("local t = { 1,\n            2 }\n", "local t = { 1,\n            2 }\n")
end

--- Indentation is the renderer's: two columns for each block a
--- statement sits inside, and a closing keyword lined up with the
--- statement that opened its block, whatever columns the source used.
local function test_indentation_is_two_columns_a_level()
  writes("local function f()\n      if x then\n            return 1\n" ..
         "      end\nend\n",
         "local function f()\n  if x then\n    return 1\n  end\nend\n")
  writes("f(function()\n        return 1\n      end)\n",
         "f(function()\n  return 1\nend)\n")
end

--- A call, an index, a method call, and a dotted name.
local function test_calls_indexes_and_methods()
  writes("local r = t:m(1, 2) + t.k + t[\"k\"] + f()\n",
         "local r = t:m(1, 2) + t.k + t[\"k\"] + f()\n")
end

--- A cast's type is the source's own bytes, spacing included, because
--- tl keeps a type's meaning, not its text.
local function test_a_cast_keeps_its_types_own_spelling()
  writes("local v = t as {string: any}\n", "local v = t as {string: any}\n")
  writes("local w = t as {string:any}\n", "local w = t as {string:any}\n")
end

--- Blocks: the closing keyword goes where the source put it, so a
--- one-line `if` stays on one line and a spread-out one stays spread.
local function test_blocks_keep_the_shape_the_source_gave_them()
  writes("if x then return 1 end\n", "if x then return 1 end\n")
  writes("if x then\n  return 1\nelseif y then\n  return 2\nelse\n" ..
         "  return 3\nend\n",
         "if x then\n  return 1\nelseif y then\n  return 2\nelse\n" ..
         "  return 3\nend\n")
  writes("for   i=1,10 ,2 do print(i) end\n",
         "for i = 1, 10, 2 do print(i) end\n")
  writes("for k, v in pairs(t) do print(k) end\n",
         "for k, v in pairs(t) do print(k) end\n")
  writes("while a>0 do a = a-1 end\n", "while a > 0 do a = a - 1 end\n")
  writes("repeat a = 1 until a > 0\n", "repeat a = 1 until a > 0\n")
  writes("do local q = 1 end\n", "do local q = 1 end\n")
end

--- A function's signature: an optional argument's `?`, a vararg's type,
--- and the return list.
local function test_function_signatures()
  writes("local function f(a:integer,b?:string,...:any)  :  integer, string\n" ..
         "  return a, b\nend\n",
         "local function f(a: integer, b?: string, ...: any): integer, string\n" ..
         "  return a, b\nend\n")
  writes("local M = {}\nfunction M.go(self: any)\nend\n" ..
         "function M:meth(a: integer)\nend\n",
         "local M = {}\nfunction M.go(self: any)\nend\n" ..
         "function M:meth(a: integer)\nend\n")
end

--- A record body is written as the bytes it was read from, comments
--- between its fields included, because tl keeps a record's fields as
--- types and would not hand those comments back.
local function test_a_record_body_keeps_its_comments()
  local source = "local record R\n  --- what bar is for\n  bar: string\nend\n" ..
                 "return R\n"
  writes(source, source)
end

--- A type alias, and a `local type` bound to a require, which is a
--- different shape entirely: an expression, not a type.
local function test_type_aliases_and_type_bound_requires()
  writes("local type T = a.b\nlocal x: T = nil\n",
         "local type T = a.b\nlocal x: T = nil\n")
  writes("local type c = require(\"build.compiler\")\nlocal y: c = nil\n",
         "local type c = require(\"build.compiler\")\nlocal y: c = nil\n")
end

--- A `;` between two statements on one line is not in the AST and
--- dropping it would run them together, so it is read back off the
--- token stream.
local function test_a_semicolon_between_statements_survives()
  writes("local t: integer; t = 1\n", "local t: integer; t = 1\n")
end

--- A literal function passed as a call argument on a line of its own:
--- its body is indented from the column the `function` keyword was
--- written at, and its `end` closes back to that same column, not to
--- the column of the statement that encloses the whole call.
local function test_a_literal_function_on_a_continuation_line()
  writes(lines({
    "local ok = apply(",
    "  { 1, 2 },",
    "  function(v)",
    "      return v",
    "        and true",
    "  end",
    ")",
  }), lines({
    "local ok = apply(",
    "  { 1, 2 },",
    "  function(v)",
    "    return v",
    "      and true",
    "  end",
    ")",
  }))
end

--- The same as a table value: the `function` keyword is not first on
--- its line, so the column it is written at is the line's indentation,
--- not the keyword's position.
local function test_a_literal_function_as_a_table_value()
  writes(lines({
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
end

--- A literal inside a literal, each on a continuation line of its own:
--- every block is indented from the one that opened it, all the way
--- down and all the way back out.
local function test_literal_functions_nested_through_continuation_lines()
  writes(lines({
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

--- A continuation line keeps its column, which need not be even, and a
--- literal opening there still gets a body two columns in from that
--- column and an `end` back at it.
local function test_a_literal_function_off_the_two_column_grid()
  writes(lines({
    "local u = { 1,",
    "   function()",
    "  return 2",
    "  end }",
  }), lines({
    "local u = { 1,",
    "   function()",
    "     return 2",
    "   end }",
  }))
end

--- A literal that opens on its statement's own line is indented from
--- the statement, by the same rule: the column the `function` keyword
--- is written at.
local function test_a_literal_function_on_its_statements_own_line()
  writes(lines({
    "local f = function()",
    "      return 1",
    "    end",
    "g(function()",
    "      return 2",
    "    end)",
  }), lines({
    "local f = function()",
    "  return 1",
    "end",
    "g(function()",
    "  return 2",
    "end)",
  }))
end

--- A long comment written across several lines with code after its
--- `]]` keeps that code on the same line, since the renderer adds no
--- break there. The blank line before the second comment covers a blank
--- owed at the same moment.
local function test_a_long_comment_closing_on_a_line_of_code()
  local source = lines({
    "--[[ a",
    "b ]] local x = 1",
    "",
    "--[[ c",
    "d",
    "e ]] local y = 2",
    "print(x, y)",
  })
  writes(source, source)
end

--- A long comment that closes on a line of its own keeps that line,
--- with what follows written under it.
local function test_a_long_comment_closing_on_its_own_line()
  local source = lines({
    "--[[ a",
    "b ]]",
    "local x = 1",
  })
  writes(source, source)
end

--- A line can carry more than one comment. Where a long comment closes
--- on it and another follows before the code, the whole line is one
--- run: each later comment a space along, and no break in it. Taking
--- only the first would put the rest after the code, which the tree
--- comparison catches and the file is refused.
local function test_several_comments_share_the_line_a_long_one_closes_on()
  local source = lines({
    "local a = 1",
    "--[[ p",
    "q ]] --[[ r ]] local x = 2",
    "print(a, x)",
  })
  writes(source, source)
  writes(lines({
    "local a = 1",
    "--[[ p",
    "q ]]     --[[ r ]]    local x = 2",
    "print(a, x)",
  }), source)
end

--- Three comments, the first two long ones each closing a line later: a
--- run follows the comments from line to line, and what shares a line
--- is decided per comment, not once for the whole gap.
local function test_three_comments_across_two_long_ones_closing()
  local source = lines({
    "local a = 1",
    "--[[ p",
    "q ]] --[[ r",
    "s ]] --[[ t ]] local x = 2",
    "print(a, x)",
  })
  writes(source, source)
end

--- A comment before the long one that closes the line is the same case
--- from the other side: the first comment must not get a break after
--- it either.
local function test_a_comment_in_front_of_a_long_one_closing_a_line()
  local source = lines({
    "local a = 1",
    "--[[ x ]] --[[ p",
    "q ]] local y = 2",
    "print(a, y)",
  })
  writes(source, source)
end

--- What follows a `]]` need not be code. A comment after it stays on
--- that line too, and the statement under it keeps its own line.
local function test_a_comment_after_a_long_ones_close_keeps_its_line()
  local source = lines({
    "local a = 1",
    "--[[ p",
    "q ]] -- tail",
    "-- under it",
    "local x = 2",
    "print(a, x)",
  })
  writes(source, source)
end

--- A comment that follows the code on such a line is that line's
--- trailing comment, written after the statement where the source had
--- it. Pulling it forward with the ones in front of the code would put
--- a `--` comment ahead of the statement and comment the line out.
local function test_a_trailing_comment_stays_behind_the_code_it_follows()
  local source = lines({
    "local a = 1",
    "--[[ p",
    "q ]] --[[ r ]] local x = 2 -- why",
    "print(a, x)",
  })
  writes(source, source)
end

--- A `global` declaration is written as a `local` one is, names,
--- attributes, type list and values, under its own keyword.
local function test_global_declarations()
  writes(lines({
    "global gfn: function(integer): integer = function(gp: integer): integer",
    "  local gl = gp",
    "  return gl",
    "end",
  }), lines({
    "global gfn: function(integer): integer = function(gp: integer): integer",
    "  local gl = gp",
    "  return gl",
    "end",
  }))
  writes("global   x=1\n", "global x = 1\n")
  writes("global y:integer\n", "global y: integer\n")
  writes("global a < const > ,b:integer, string=1,\"x\"\n",
         "global a <const>, b: integer, string = 1, \"x\"\n")
end

--- A `global function` and a bare `function g`, which tl reads as the
--- same kind of node, each keep the keywords the source gave them.
local function test_global_functions()
  writes("global  function g(a:integer):integer\n      return a\nend\n",
         "global function g(a: integer): integer\n  return a\nend\n")
  writes("function h() end\n", "function h() end\n")
  writes("global function k<T>(t: T): T return t end\n",
         "global function k<T>(t: T): T return t end\n")
  writes("if x then\nglobal function m()\nend\nend\n",
         "if x then\n  global function m()\n  end\nend\n")
end

--- `global record`, `global enum` and `global interface` are written
--- as the bytes they were read from, as a `local` one is; a `global
--- type` is an alias, a bound require, or a name alone, declared with
--- nothing after it.
local function test_global_types()
  local record_body = "global record R\n  --- what bar is for\n  bar: string\nend\n"
  writes(record_body, record_body)
  writes("global enum E\n  \"a\"\nend\n", "global enum E\n  \"a\"\nend\n")
  writes("global interface I\n  x: integer\nend\n",
         "global interface I\n  x: integer\nend\n")
  writes("global  type T=integer\n", "global type T = integer\n")
  writes("global type L<X> = {X}\n", "global type L<X> = {X}\n")
  writes("global type c = require(\"build.compiler\")\n",
         "global type c = require(\"build.compiler\")\n")
  writes("global   type   U\n", "global type U\n")
  writes("global type V<X>\n", "global type V<X>\n")
end

--- `local type T = record ... end` spells the same record with its
--- name ahead of the keyword. The statement's bytes are copied from its
--- `local`, not from the `record`, or the name would be lost.
local function test_a_record_bound_by_a_type_declaration()
  writes("local type T = record\n  x: integer\nend\n",
         "local type T = record\n  x: integer\nend\n")
  writes("global type G = enum\n  \"a\"\nend\n",
         "global type G = enum\n  \"a\"\nend\n")
end

--- A `local macroexp` is a signature and one `return`, laid out as a
--- `local function` is: the `return` indented a level, the `end` lined
--- up with the `local`.
local function test_a_local_macroexp()
  writes("local  macroexp m(a:integer):integer\n      return a+1\n   end\n",
         "local macroexp m(a: integer): integer\n  return a + 1\nend\n")
  writes("local macroexp n(): integer return 1 end\n",
         "local macroexp n(): integer return 1 end\n")
  writes("do\nlocal macroexp p(a: integer, b: integer): integer\n" ..
         "return a +\n  b\nend\nend\n",
         "do\n  local macroexp p(a: integer, b: integer): integer\n" ..
         "    return a +\n      b\n  end\nend\n")
end

--- A pragma is written as its name and value, indented as any other
--- statement is.
local function test_a_pragma()
  writes("--#pragma   arity   on\nprint(1)\n", "--#pragma arity on\nprint(1)\n")
  writes("do\n--#pragma arity off\nend\n", "do\n  --#pragma arity off\nend\n")
end

--- A node of a kind this renderer has no spelling for is named and
--- refused, rather than written as something else.
local function test_an_unknown_construct_is_refused_by_name()
  local source = "print(1)\n"
  local parsed = ast.parse(built, source, "unknown.tl")
  assert(parsed ~= nil, "the fixture should parse")
  parsed.node[1].kind = "invented_kind"
  local result, trouble = render.rendered(parsed, source)
  assert(result == nil, "an unknown kind should be refused")
  assert(trouble:find("invented_kind", 1, true) ~= nil, "got: " .. trouble)
end

--- A `#!` line is no statement and carries no comment, and the tree
--- holds it all the same: it is written first, before any statement,
--- and with none at all.
local function test_a_hashbang_line_is_kept()
  writes("#!/usr/bin/env cosmic\nprint(1)\n", "#!/usr/bin/env cosmic\nprint(1)\n")
  writes("#!/usr/bin/env cosmic\n", "#!/usr/bin/env cosmic\n")
end

--- A `;` is part of the tree wherever it is: after a block's last
--- statement, in front of its first, and after a `return` with no
--- values. A run of them is one.
local function test_a_semicolon_at_either_end_of_a_block_survives()
  writes("x = 1;", "x = 1;\n")
  writes("do x = 1;; end\n", "do x = 1; end\n")
  writes("; x = 1\n", "; x = 1\n")
  writes("do ; x = 1 end\n", "do ; x = 1 end\n")
  writes("return;", "return;\n")
end

--- Two `-` written together open a comment, and `[[` a long string:
--- a unary minus keeps its space from another, and a key or index that
--- opens with a long string keeps its space from the bracket.
local function test_tokens_that_would_run_together_are_kept_apart()
  writes("x = - -y\n", "x = - -y\n")
  writes("x = t[ [[a]] ]\n", "x = t[ [[a]] ]\n")
  writes("x = {[ [=[a]=] ] = 1}\n", "x = { [ [=[a]=] ] = 1 }\n")
end

--- A statement that continues a line, after a `;` or a block's opening
--- keyword, moves by where that line reaches, and the lines continuing
--- it move with it.
local function test_a_statement_continuing_a_line_carries_its_continuation()
  writes("x = 1;    b = f(1,\n                2)\n", "x = 1; b = f(1,\n             2)\n")
  writes("do b =\n      1 end\n", "do b =\n      1 end\n")
end

--- `integer` is a whole type, so the `<` after it in a cast is the
--- comparison, not type arguments.
local function test_a_comparison_after_a_cast_to_a_simple_type()
  writes("x = a as integer < b\n", "x = a as integer < b\n")
  writes("x = a as R<integer> < b\n", "x = a as R<integer> < b\n")
end

--- A `goto`'s label, and a label's name and closing `::`, stay on the
--- lines the source put them on.
local function test_a_goto_and_a_label_keep_their_line_breaks()
  writes("goto -- why\ncontinue ::continue::\n", "goto -- why\ncontinue ::continue::\n")
  writes("::\ntop ::\n", "::\ntop::\n")
end
