--- What `cosmic fix` writes, checked against the exact text expected,
--- one construct at a time.
---
--- The `<const>`/`<close>` cases are the reason this file leads with
--- them. cosmic's predecessor re-emitted source from a TOKEN STREAM and
--- never special-cased a variable attribute, so `local x <const> = 5`
--- came back as `local x < const > = 5` -- three bare tokens spaced by
--- a rule about adjacency -- and shipped that way in 374 places,
--- because the only tests were that the formatter agreed with itself.
--- Here the attribute is a FIELD on the variable's own node and is
--- written as one unit attached to the name, so there is no spacing
--- decision to get wrong; these cases are what says so out loud. The
--- tree this tool renders uses neither attribute anywhere, so nothing
--- else would ever exercise them.
---
--- Every case goes through the whole verb, `build.fix.source`, not the
--- renderer alone: that reparses what it wrote and compares the trees,
--- so a golden string here is checked for meaning as well as for text.

local fix = require("build.fix")
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

--- A `<const>` is one unit against the name, with a single space in
--- front of it and none inside the angle brackets -- whatever spacing
--- the source used.
local function test_a_const_attribute_hugs_its_angle_brackets()
  writes("local x <const> = 5\n", "local x <const> = 5\n")
  writes("local    x    <const>    =    5\n", "local x <const> = 5\n")
end

--- The spelling a token-adjacency rule produces, fed back in: the
--- renderer reads the attribute off the node and writes the one correct
--- form, so this is the case that says the old bug cannot come back.
local function test_a_spaced_out_attribute_is_written_back_closed_up()
  writes("local x < const > = 5\n", "local x <const> = 5\n")
  writes("local y < close > : integer = 6\n", "local y <close>: integer = 6\n")
end

--- The attribute comes BEFORE the type annotation. `local y: integer
--- <close> = 6` is not Teal at all, so there is only one order to write
--- and this is it.
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

--- A cast's type is the source's own bytes, spacing and all, because
--- tl keeps a type's meaning rather than its text.
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

--- A `;` between two statements on one line is not in the AST, and
--- dropping it would run them together, so it is read back off the
--- token stream.
local function test_a_semicolon_between_statements_survives()
  writes("local t: integer; t = 1\n", "local t: integer; t = 1\n")
end

--- A construct this renderer has no spelling for is named and refused,
--- rather than written as something else.
local function test_an_unknown_construct_is_refused_by_name()
  local result, trouble = fix.source(built, "local macroexp m(): integer\n" ..
                                     "  return 1\nend\n", "macro.tl")
  assert(result == nil, "a macroexp should be refused")
  assert(trouble:find("local_macroexp", 1, true) ~= nil, "got: " .. trouble)
end
