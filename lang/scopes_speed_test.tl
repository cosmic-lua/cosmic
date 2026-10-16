--- The speed of the scope builder ([`lang.scopes`]), held to ratios and never
--- to a clock: a slow machine slows every side of a ratio alike. Building the
--- scopes of a parsed program costs a fraction of parsing it, and four times
--- the input costs about four times the time, for each form that could cost
--- more than its length (a long chain, a block of many locals, many functions
--- that capture one variable, many assignments to it, unknown names that each
--- ask for the nearest name, types used before they are declared).
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{}

local GLOBALS <const>: {string: Scopes.Global} = {
  print = { space = "value", const = true },
  ipairs = { space = "value", const = true },
}

--- The statements of a program to repeat, each repetition in a block of its own.
local SAMPLE <const> = [[
do
  local interface Resettable
    label: string
  end
  local class Counter is Resettable
    label: string
    mut count: integer
    function bump(self, by: integer): integer
      self.count = self.count + by
      return self.count
    end
  end
  local function count(xs: {integer}, skip: integer?): integer
    local n = 0
    for _, x in ipairs(xs) do if x == skip then continue end n = n + 1 end
    return n
  end
  local total = 0
  local add = function(k) return total + k end
  total = add(count({ 1, 2 }))
  repeat local done = total > 3 until done
  print(total)
end
]]

local function parsed(source: string): Parser.Parsed
  return Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
end

local function test_building_scopes_costs_a_fraction_of_parsing()
  local source = SAMPLE:rep(100)
  local lexed = Lexer.lex(source, "t.tl")
  local chunk = Parser.parse(lexed, "t.tl", "tl").chunk
  assert(#Scopes.build(chunk, "t.tl", GLOBALS).errors == 0, "the sample resolves clean")
  local ok, why = Speed.within(function()
    local _ = Parser.parse(lexed, "t.tl", "tl")
  end, function()
    local _ = Scopes.build(chunk, "t.tl", GLOBALS)
  end, 2)
  assert(ok, "building " .. why)
end

--- Forms that a scope builder could make slower than their length, each as a function of how many to write.
local FORMS <const>: {string: function(n: integer): string} = {
  statements = function(n: integer): string return SAMPLE:rep(n) end,
  ["a left-associative chain"] = function(n: integer): string
    return "local a = 1\nlocal x = a" .. (" + a"):rep(n * 100)
  end,
  ["a block of locals"] = function(n: integer): string
    local out: {string} = {}
    for i = 1, n * 50 do
      out[i] = "local v" .. i .. " = " .. (i > 1 and "v" .. (i - 1) or "1") .. "\n"
    end
    return table.concat(out)
  end,
  ["a name declared again and again"] = function(n: integer): string
    return ("local x = 1\n"):rep(n * 50)
  end,
  ["functions that capture one variable"] = function(n: integer): string
    return "local x = 1\n" .. ("local f = function() return x end\n"):rep(n * 50) .. "x = 2\n"
  end,
  ["assignments to a captured variable"] = function(n: integer): string
    return "local x = 1\nlocal f = function() return x end\n" .. ("x = 2\n"):rep(n * 50)
  end,
  ["captures inside loops"] = function(n: integer): string
    return "local x = 1\n" .. ("for i = 1, 2 do x = i local f = function() return x end end\n"):rep(n * 20)
  end,
  ["unknown names"] = function(n: integer): string
    return ("print(nothing_" .. "x, name_y)\n"):rep(n * 50)
  end,
  ["unknown names declared later"] = function(n: integer): string
    return ("print(late)\n"):rep(n * 50) .. ("local late = 1\n"):rep(n * 5)
  end,
  ["types declared later"] = function(n: integer): string
    local out: {string} = {}
    for i = 1, n * 25 do
      out[i] = "local function f" .. i .. "(x: T" .. i .. "): T" .. i .. " end\n"
    end
    for i = 1, n * 25 do out[#out + 1] = "local record T" .. i .. " end\n" end
    return table.concat(out)
  end,
  ["blocks nested"] = function(n: integer): string
    return ("do local y = 1 "):rep(150) .. ("print(y) "):rep(n * 20) .. ("end "):rep(150)
  end,
  ["a field chain"] = function(n: integer): string
    return "local a = {}\nlocal x = a" .. (".f"):rep(n * 100)
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local small_chunk = parsed(form(15)).chunk
    local large_chunk = parsed(form(60)).chunk
    local ok, why = Speed.within(function()
      local _ = Scopes.build(small_chunk, "t.tl", GLOBALS)
    end, function()
      local _ = Scopes.build(large_chunk, "t.tl", GLOBALS)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end
