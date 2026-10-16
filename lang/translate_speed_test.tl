--- The speed of the translator ([`lang.translate`]), held to ratios and never
--- to a clock: a slow machine slows every side of a ratio alike. A translation
--- costs a small multiple of parsing the same source, and four times the
--- input costs about four times the time, for each form that could cost more
--- than its length (a long chain of ternaries, a long union, a class of many
--- methods, many statements).
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Speed = require("lang.speed")
local Translate = require("lang.translate")

--- Statements of Teal that every row of the translator rewrites, to repeat.
local SAMPLE <const> = [[
local type Point = record
  x: number | nil
  metamethod __close: function(Point)
end
local a: A | B | nil = nil
local n = 1_000 + 0x1p4
for i = 1, 3 do
  if i == 2 then goto continue end
  local s = i == 1 and "one" or "many"
  ::continue::
end
local f: function(string..., ? integer): (function(): R) | nil
]]

local function test_translating_costs_a_small_multiple_of_parsing()
  local source = SAMPLE:rep(20)
  local ok, why = Speed.within(function()
    local _ = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
  end, function()
    local _ = Translate.translate(source, "t.tl")
  end, 12)
  assert(ok, "translating " .. why)
end

--- Forms that could cost more than their length, each as a function of how many to write.
local FORMS <const>: {string: function(n: integer): string} = {
  statements = function(n: integer): string return SAMPLE:rep(n) end,
  ["a chain of ternaries"] = function(n: integer): string
    return "local x = " .. ("a and 1 or "):rep(n * 25) .. "2"
  end,
  ["a long union"] = function(n: integer): string
    return "local x: A" .. (" | B"):rep(n * 25) .. " | nil"
  end,
  ["many unions in one line"] = function(n: integer): string
    return "local x: function(" .. ("a: A | nil, "):rep(n * 20) .. "b: B | nil)"
  end,
  ["a class of many methods"] = function(n: integer): string
    local out: {string} = { "local record R\n  n: integer\nend\n" }
    for i = 1, n * 10 do
      out[#out + 1] = "local v" .. i .. " = " .. i .. "\n"
      out[#out + 1] = "function R:m" .. i .. "(a: string | nil): integer\n  self.n = v" .. i .. "\n  return 1\nend\n"
    end
    return table.concat(out)
  end,
  ["many records with fields"] = function(n: integer): string
    local out: {string} = {}
    for i = 1, n * 10 do
      out[#out + 1] = "local record R" .. i .. "\n  a: integer\n  b: {string}\nend\n"
      out[#out + 1] = "local function f" .. i .. "(r: R" .. i .. ", xs: {integer})\n  r.a = 1\n  xs[1] = 2\nend\n"
    end
    return table.concat(out)
  end,
  ["many semicolons"] = function(n: integer): string return ("x = 1;"):rep(n * 100) end,
  ["a table of many semicolons"] = function(n: integer): string
    return "local t = {" .. ("1; k = 2; {3; 4}; "):rep(n * 30) .. "}"
  end,
  ["many long comments"] = function(n: integer): string return ("--[[ c ]]\n"):rep(n * 100) end,
  ["nested unions"] = function(n: integer): string
    local depth = math.min(n * 3, 90)
    return "local x: " .. ("function(a: "):rep(depth) .. "A | nil" .. (") | nil"):rep(depth)
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local small, large = form(4), form(16)
    local ok, why = Speed.within(function()
      local _ = Translate.translate(small, "t.tl")
    end, function()
      local _ = Translate.translate(large, "t.tl")
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end
