--- The speed of the code generator ([`lang.codegen`]), held to ratios and never to a clock: a slow machine slows
--- every side of a ratio alike. Writing the Lua of a parsed program costs a small multiple of parsing it, and four
--- times the input costs about four times the time, for each form that could cost more than its length (a chain of
--- operands, of calls or of fields, a block of statements, a long list, a table of tables, blocks that nest, a
--- chain of `elseif`).
local Codegen = require("lang.codegen")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{}

--- The statements of a program to repeat.
local SAMPLE <const> = [[
local record Point
  x: integer
  record Inner
  end
end
local function count(xs: {integer}, skip: integer?): integer
  local n = 0
  for _, x in ipairs(xs) do
    if x == skip then continue end
    n = n + (x is integer and 1 or 0)
  end
  return n
end
local t = { a = 1, [2] = "two", { 3, 4 }, f = function(v) return v .. "s" end }
while count(t) < 10 do
  t.a = t.a + #t
  repeat t.a = t.a - 1 until t.a < 5
end
function Point.make(): Point return { x = 0 } end
]]

local function parsed(source: string): Parser.Parsed
  return Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
end

local function written(tree: Parser.Parsed): string
  return Codegen.generate(tree.chunk, Scopes.build(tree.chunk, "t.tl", {})).text
end

local function test_writing_lua_costs_a_small_multiple_of_parsing_and_scoping()
  local source = SAMPLE:rep(60)
  local lexed = Lexer.lex(source, "t.tl")
  local tree = Parser.parse(lexed, "t.tl", "tl")
  assert(#tree.errors == 0 and #Codegen.generate(tree.chunk, Scopes.build(tree.chunk, "t.tl", {})).errors == 0,
    "the sample is clean")
  local ok, why = Speed.within(function()
    local _ = Scopes.build(Parser.parse(lexed, "t.tl", "tl").chunk, "t.tl", {})
  end, function()
    local _ = Codegen.generate(tree.chunk, Scopes.build(tree.chunk, "t.tl", {}))
  end, 4)
  assert(ok, "generating " .. why)
end

--- Forms that a generator could make slower than their length, each as a function of how many to write.
local FORMS <const>: {string: function(n: integer): string} = {
  statements = function(n: integer): string return SAMPLE:rep(n) end,
  ["a left-associative chain"] = function(n: integer): string
    return "local a = 1\nlocal x = a" .. (" + a"):rep(n * 100)
  end,
  ["a chain of calls"] = function(n: integer): string
    return "local f = print\nf" .. ("()"):rep(n * 100)
  end,
  ["a chain of fields and indexes"] = function(n: integer): string
    return "local a = {}\nlocal x = a" .. (".f[1]"):rep(n * 50)
  end,
  ["a chain of method calls"] = function(n: integer): string
    return "local a = {}\nlocal x = a" .. (":m(1)"):rep(n * 50)
  end,
  ["a chain of tests"] = function(n: integer): string
    return "local a: any = 1\nlocal x = a is string" .. (" and a is integer"):rep(n * 50)
  end,
  ["a block of locals"] = function(n: integer): string
    local out: mut {string} = {}
    for i = 1, n * 50 do
      out[i] = "local v" .. i .. " = " .. (if i > 1 then "v" .. (i - 1) else "1" end) .. "\n"
    end
    return table.concat(out)
  end,
  ["statements on one line"] = function(n: integer): string
    return ("local a = 1 "):rep(n * 50)
  end,
  ["a long argument list"] = function(n: integer): string
    return "print(1" .. (", 2"):rep(n * 100) .. ")"
  end,
  ["a long table"] = function(n: integer): string
    return "local t = {\n" .. ("  1,\n"):rep(n * 100) .. "}"
  end,
  ["tables nested"] = function(n: integer): string
    return ("local t = { { a = { 1 }, b = {} }, 2 }\n"):rep(n * 25)
  end,
  ["blocks nested"] = function(n: integer): string
    return ("do local y = 1 "):rep(150) .. ("print(y) "):rep(n * 20) .. ("end "):rep(150)
  end,
  ["a chain of elseif"] = function(n: integer): string
    return "local x = 1\nif x == 0 then\n" .. ("elseif x == 1 then\n"):rep(n * 50) .. "end"
  end,
  ["an if expression of many arms"] = function(n: integer): string
    return "local x = 1\nlocal y = if x == 0 then 1" .. (" elseif x == 2 then 3"):rep(n * 50) .. " else 4 end"
  end,
  ["a long string"] = function(n: integer): string
    return "local s = [[" .. ("line\n"):rep(n * 100) .. "]]"
  end,
  ["a record of nested records"] = function(n: integer): string
    return "local record R\n" .. ("  record N\n  end\n"):rep(n * 25) .. "end\nR.x = 1"
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local small, large = parsed(form(6)), parsed(form(24))
    assert(#small.errors == 0 and #large.errors == 0, name .. " parses")
    local small_scoped = Scopes.build(small.chunk, "t.tl", {})
    local large_scoped = Scopes.build(large.chunk, "t.tl", {})
    local ok, why = Speed.within(function()
      local _ = Codegen.generate(small.chunk, small_scoped)
    end, function()
      local _ = Codegen.generate(large.chunk, large_scoped)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end

--- A chain of a hundred thousand operands, calls and fields is written, not run out of stack on.
local function test_a_chain_of_a_hundred_thousand_is_written_without_recursion_on_its_length()
  local operands = parsed("local a = 1\nlocal x = a" .. (" + a"):rep(100000))
  assert(written(operands) == "local a = 1\nlocal x = a" .. (" + a"):rep(100000))
  local fields = parsed("local a = {}\nlocal x = a" .. (".f"):rep(100000))
  assert(written(fields) == "local a = {}\nlocal x = a" .. (".f"):rep(100000))
  local calls = parsed("local f = print\nf" .. ("()"):rep(100000))
  assert(written(calls) == "local f = print\nf" .. ("()"):rep(100000))
end
