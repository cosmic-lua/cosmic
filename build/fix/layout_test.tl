--- [`build.fix.layout`] over tiny sources: the spacing of a line from the roles of its tokens, checked against
--- the text the previous formatter wrote for the same construct, and the properties that hold for any source:
--- no token or comment changes, laying out what is laid out changes nothing, and the spacing the author wrote
--- outside a type does not reach the result.
local Fs = require("cosmic.fs")
local Layout = require("build.fix.layout")
local Lexer = require("lang.lexer")
local Roles = require("build.fix.roles")
local Parser = require("lang.parser")
local Test = require("cosmic.test")
local Trivia = require("build.fix.trivia")

Test.policy{
  grants = {
    { path = "build/fix/trivia.tl", letters = "r" }, { path = "build/fix/roles.tl", letters = "r" },
    { path = "build/fix/layout.tl", letters = "r" }, { path = "build/fix/near.tl", letters = "r" },
    { path = "lang/ast_dump.tl", letters = "r" },
  },
}

--- The kind and text of each token of `source` and the text of each comment, in order.
local function tokens_of(source: string): string
  local lexed = Lexer.lex(source, "f.tl")
  local out: mut {string} = {}
  for _, item in ipairs(Trivia.of(source, lexed.tokens).items) do
    out[#out + 1] = item.kind .. ":" .. item.text
  end
  return table.concat(out, "\0")
end

--- `source` laid out, which must succeed with the tokens and comments of `source` and be a fixed point.
local function laid(source: string): string
  local got, why = Layout.of(source, "f.tl")
  assert(got ~= nil, string.format("%q refused: %s", source, why))
  assert(tokens_of(got) == tokens_of(source), string.format("%q changed tokens: %q", source, got))
  local again = Layout.of(got, "f.tl")
  assert(again == got, string.format("%q is not a fixed point: %q then %q", source, got, tostring(again)))
  return got
end

--- Asserts that `source` is laid out as `want`.
local function lays(source: string, want: string)
  local got = laid(source)
  assert(got == want, string.format("%q\n got %q\nwant %q", source, got, want))
end

local function test_a_const_attribute_hugs_its_angle_brackets()
  lays("local x <const> = 5\n", "local x <const> = 5\n")
  lays("local    x    <const>    =    5\n", "local x <const> = 5\n")
  lays("local x < const > = 5\n", "local x <const> = 5\n")
end

local function test_an_attribute_comes_before_the_annotation()
  lays("local y < close > : integer = 6\n", "local y <close>: integer = 6\n")
  lays("local a < const > ,b<close>:integer, string=1,\"x\"\n", "local a <const>, b <close>: integer, string = 1, \"x\"\n")
end

local function test_operators_and_separators_are_spaced_from_the_roles()
  lays("local s = x+1 ..  \"a\"\n", "local s = x + 1 .. \"a\"\n")
  lays("local z:integer=7\n", "local z: integer = 7\n")
  lays("local t = {1,2 ,  3}\n", "local t = { 1, 2, 3 }\n")
  lays("print( x )\n", "print(x)\n")
  lays("a,b = b ,a\n", "a, b = b, a\n")
  lays("x = a<b and c>=d or e~=f\n", "x = a < b and c >= d or e ~= f\n")
end

local function test_unary_operators_hug_their_operand_but_not()
  lays("local a = -x + not y + #z + ~w\n", "local a = -x + not y + #z + ~w\n")
  lays("local a = - x+ not   y+# z\n", "local a = -x + not y + #z\n")
  lays("x = - -y\n", "x = - -y\n")
  lays("x = a - -b\n", "x = a - -b\n")
  lays("x = - not a\n", "x = -not a\n")
  lays("x = -(a + b) * #(t)\n", "x = -(a + b) * #(t)\n")
end

local function test_a_minus_before_a_minus_keeps_its_space_so_that_no_comment_opens()
  lays("x = - - y\n", "x = - -y\n")
  lays("x = a--b\n", "x = a --b\n")
end

local function test_table_literal_keys_and_brace_gaps()
  lays("local t = { a = 1, [\"b\"] = 2, 3 }\n", "local t = { a = 1, [\"b\"] = 2, 3 }\n")
  lays("local t = {a = 1, 2}\n", "local t = { a = 1, 2 }\n")
  lays("local t = { [ \"b\" ]=2 }\n", "local t = { [\"b\"] = 2 }\n")
  lays("local t = {  }\n", "local t = {}\n")
  lays("local t = {{},{ }}\n", "local t = { {}, {} }\n")
  lays("f({1}, {})\n", "f({ 1 }, {})\n")
  lays("t = { -- c\n}\n", "t = { -- c\n}\n")
  lays("t = { 1, 2, }\n", "t = { 1, 2, }\n")
end

local function test_a_key_or_index_that_begins_with_a_long_string_stands_off_its_brackets()
  lays("x = t[ [[a]] ]\n", "x = t[ [[a]] ]\n")
  lays("x = {[ [=[a]=] ] = 1}\n", "x = { [ [=[a]=] ] = 1 }\n")
  lays("x = t[ \"a\" ]\n", "x = t[\"a\"]\n")
end

local function test_calls_indexes_and_methods_are_closed_up()
  lays("local r = t:m(1, 2) + t.k + t[\"k\"] + f()\n", "local r = t:m(1, 2) + t.k + t[\"k\"] + f()\n")
  lays("local r = t : m ( 1 ) . k [ 2 ] ( 3 )\n", "local r = t:m(1).k[2](3)\n")
  lays("return (f)(x), (a)\n", "return (f)(x), (a)\n")
  lays("f(g(h( 1, 2 ), ...))\n", "f(g(h(1, 2), ...))\n")
end

local function test_a_types_own_spacing_is_kept()
  lays("local v = t as {string: any}\n", "local v = t as {string: any}\n")
  lays("local w = t as {string:any}\n", "local w = t as {string:any}\n")
  lays("local w = t as {  string :  any }\n", "local w = t as {  string :  any }\n")
  lays("local m: metatable<R<K>> = {}\n", "local m: metatable<R<K>> = {}\n")
  lays("local a:  {string}|nil2\n", "local a: {string}|nil2\n")
end

local function test_a_parenthesized_type_keeps_its_parentheses_in_the_type()
  lays("local y = x as (T | U)\n", "local y = x as (T | U)\n")
  lays("local y = x   is  ( T )\n", "local y = x is ( T )\n")
  lays("local b:(integer)=1\n", "local b: (integer) = 1\n")
  lays("local type A=((T | U))\n", "local type A = ((T | U))\n")
  lays("f(x as T)\n", "f(x as T)\n")
end

local function test_a_shift_is_a_binary_operator_and_not_the_close_of_type_arguments()
  lays("x = a>>b\n", "x = a >> b\n")
  lays("x = a as integer\n", "x = a as integer\n")
end

local function test_function_signatures()
  lays("local function f(a:integer,b?:string,...:any)  :  integer, string return a, b end\n",
    "local function f(a: integer, b?: string, ...: any): integer, string return a, b end\n")
  lays("local M = {}\nfunction M.go(self: any) end\n", "local M = {}\nfunction M.go(self: any) end\n")
  lays("local function k<T , U>(t:T):T return t end\n", "local function k<T, U>(t: T): T return t end\n")
  lays("local f = function( a , b ) return a end\n", "local f = function(a, b) return a end\n")
  lays("g(function ( v ) return v end)\n", "g(function(v) return v end)\n")
end

local function test_loops_and_blocks_on_a_line()
  lays("for   i=1,10 ,2 do print(i) end\n", "for i = 1, 10, 2 do print(i) end\n")
  lays("for k,v in pairs( t ) do print(k) end\n", "for k, v in pairs(t) do print(k) end\n")
  lays("while a>0 do a = a-1 end\n", "while a > 0 do a = a - 1 end\n")
  lays("repeat a = 1 until a>0\n", "repeat a = 1 until a > 0\n")
  lays("do local q = 1 end\n", "do local q = 1 end\n")
  lays("if x then return 1 else return(2) end\n", "if x then return 1 else return (2) end\n")
end

local function test_a_type_alias_and_a_type_bound_require()
  lays("local type T=a.b\n", "local type T = a.b\n")
  lays("local type L<X> =  {X}\n", "local type L<X> = {X}\n")
  lays("local type c = require( \"build.compiler\" )\n", "local type c = require(\"build.compiler\")\n")
end

local function test_the_constructs_the_old_formatter_did_not_have()
  lays("local v = if a  then b  elseif c then d else e end\n", "local v = if a then b elseif c then d else e end\n")
  lays("local v = f(if a then 1 else -1 end)\n", "local v = f(if a then 1 else -1 end)\n")
  lays("match f(x)do\n|(true,v)then print(v)\n|( false , _ )then print(1) end\n",
    "match f(x) do\n| (true, v) then print(v)\n| (false, _) then print(1) end\n")
  lays("local b = x   is   string and y is {string}\n", "local b = x is string and y is {string}\n")
  lays("while a do continue end\n", "while a do continue end\n")
  lays("local record R\n  mut items:{string}\n  name ?:string\n  [\"a b\"]?:  T\nend\n",
    "local record R\nmut items: {string}\nname?: string\n[\"a b\"]?: T\nend\n")
  lays("local class C\n  function get( self ):integer return 1 end\nend\n",
    "local class C\nfunction get(self): integer return 1 end\nend\n")
  lays("local function g(...:string): (integer, string)  return 1, \"\" end\n",
    "local function g(...: string): (integer, string) return 1, \"\" end\n")
end

local function test_a_comment_keeps_its_line_and_a_trailing_one_follows_one_space_after_the_code()
  lays("x=1   -- why\n", "x = 1 -- why\n")
  lays("-- a\nx=1\n--b\n", "-- a\nx = 1\n--b\n")
  lays("f(a,\n b) -- t\n", "f(a,\nb) -- t\n")
  lays("-- only", "-- only\n")
end

local function test_line_endings_become_breaks_and_blank_runs_become_one_blank_line()
  lays("a=1\r\nb=2\r\n\r\n\r\n\r\nc=3\n", "a = 1\nb = 2\n\nc = 3\n")
  lays("a=1\rb=2\n\rc=3", "a = 1\nb = 2\nc = 3\n")
  lays("\n\n\nx=1\n\n\n", "x = 1\n")
  lays("#!/bin/cosmic -x\n\n\nx=1", "#!/bin/cosmic -x\n\nx = 1\n")
  lays("#!/bin/cosmic\nx=1", "#!/bin/cosmic\nx = 1\n")
  lays("", "")
  lays("\n", "")
end

local function test_a_long_string_keeps_its_bytes()
  lays("x = [[a\r\n  b]]  ..  'c\\\r\nd'\n", "x = [[a\r\n  b]] .. 'c\\\r\nd'\n")
end

local function test_a_source_with_an_error_is_refused_in_the_parsers_words()
  local got, why = Layout.of("x = = 1\n", "bad.tl")
  assert(got == nil and why:find("^bad.tl:1:5: ") ~= nil, why)
  local lexical = Layout.of("x = 1;\n", "bad.tl")
  assert(lexical == nil)
end

--- Sources already laid out, each of which must lay out as itself, and from which the next test spoils the
--- spacing.
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
  "match f(x) do\n| (true, v) then print(v)\n| (false, _) then print(1) end\n",
  "local w = t as {string:any} -- kept\nlocal u = t is string\n",
  "-- own line\nx = f(function(a, b) return a end, {}) -- trail\n\ny = 1\n",
  "local record R\nmut items: {string}\nname?: string\n[\"a b\"]?: T\nend\n",
}

--- A pseudo-random whitespace gap between two tokens on a line.
local GAPS <const>: {string} = { " ", "  ", "\t", " \t ", "   " }

--- `source` with the gap between each two neighbours on a line replaced by a draw of `GAPS`, except inside a
--- type, where the gap is the author's own.
local function spoiled(source: string, seed: integer): string
  local lexed = Lexer.lex(source, "f.tl")
  local parsed = Parser.parse(lexed, "f.tl", "tl")
  local roled = Roles.of(parsed.chunk)
  local stream = Trivia.of(source, lexed.tokens)
  local out: mut {string} = {}
  local state = seed
  for i, item in ipairs(stream.items) do
    local before = stream.items[i - 1]
    if item.kind ~= "eof" then
      if i == 1 then
        out[#out + 1] = ""
      elseif item.newlines > 0 then
        out[#out + 1] = ("\n"):rep(item.newlines)
      elseif before ~= nil and before.kind == "token" and item.kind == "token" and
          roled.regions[item.token] ~= 0 and roled.regions[item.token] == roled.regions[before.token] then
        out[#out + 1] = source:sub(before.offset + #before.text, item.offset - 1)
      else
        state = (state * 1103515245 + 12345) % 2147483648
        out[#out + 1] = GAPS[state // 65536 % #GAPS + 1] or " "
      end
      out[#out + 1] = item.text
    end
  end
  return table.concat(out)
end

local function test_laid_out_sources_are_fixed_points()
  for _, source in ipairs(CANON) do
    lays(source, source)
  end
end

local function test_the_whitespace_an_author_wrote_outside_a_type_does_not_reach_the_result()
  for _, source in ipairs(CANON) do
    for seed = 1, 6 do
      local spoilt = spoiled(source, seed)
      lays(spoilt, source)
    end
  end
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

local function test_real_modules_keep_their_tokens_and_comments_and_lay_out_to_a_fixed_point()
  for _, path in ipairs({ "build/fix/trivia.tl", "build/fix/roles.tl", "build/fix/layout.tl", "build/fix/near.tl",
      "lang/ast_dump.tl" }) do
    local source = assert(Fs.read(path))
    local first = laid(source)
    assert(lines_of(first) == lines_of(source), path .. " gained or lost a line")
  end
end
