--- The speed of the new checker's parser ([`lang.parser`]), held to ratios
--- and never to a clock: a slow machine slows every side of a ratio alike. The
--- parser costs a small multiple of the lexer's time, and four times the input
--- costs about four times the time, for each form that could cost more than its
--- length (a long chain, a long list, a run of errors, constructs left open).
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Speed = require("lang.speed")

--- The statements of a program of the grammar, to repeat.
local SAMPLE <const> = [[
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
local noun = if count({ 1, 2 }) == 1 then "item" else "items" end
match fetch(noun) do
  | (true, body) then print(body)
  | (false, why) then print("failed: " .. why)
end
]]

local function test_parsing_costs_a_small_multiple_of_lexing()
  local source = SAMPLE:rep(100)
  local lexed = Lexer.lex(source, "t.tl")
  assert(#Parser.parse(lexed, "t.tl", "tl").errors == 0, "the sample parses clean")
  local ok, why = Speed.within(function()
    local _ = Lexer.lex(source, "t.tl")
  end, function()
    local _ = Parser.parse(lexed, "t.tl", "tl")
  end, 12)
  assert(ok, "parsing " .. why)
end

--- Forms that a parser could make slower than their length, each as a function of how many to write.
local FORMS <const>: {string: function(n: integer): string} = {
  statements = function(n: integer): string return SAMPLE:rep(n) end,
  ["a left-associative chain"] = function(n: integer): string
    return "local x = a" .. (" + a"):rep(n * 100)
  end,
  ["a table"] = function(n: integer): string
    return "local x = {" .. ("1, k = 2, [3] = f(),"):rep(n * 20) .. "}"
  end,
  ["an argument list"] = function(n: integer): string
    return "f(" .. ("a, "):rep(n * 100) .. "a)"
  end,
  ["an elseif chain"] = function(n: integer): string
    return "if a then b() " .. ("elseif c then d() "):rep(n * 25) .. "end"
  end,
  ["a record"] = function(n: integer): string
    local fields: mut {string} = {}
    for i = 1, n * 25 do fields[i] = "f" .. i .. ": integer\n" end
    return "local record R\n" .. table.concat(fields) .. "end"
  end,
  ["a match"] = function(n: integer): string
    return "match f() do\n" .. ("| (true, v) then g(v)\n"):rep(n * 15) .. "end"
  end,
  ["a union"] = function(n: integer): string return "local x: A" .. (" | B"):rep(n * 100) end,
  ["errors"] = function(n: integer): string
    return ("local x = = 1\nlocal y: T | nil\n) ) )\n"):rep(n * 5)
  end,
  ["constructs left open"] = function(n: integer): string
    return ("do "):rep(190) .. ("x = 1\n"):rep(n * 100)
  end,
  ["constructs left open over indented locals"] = function(n: integer): string
    return ("do "):rep(190) .. ("  local y = 1\n"):rep(n * 50)
  end,
  ["a run of comments before a declaration"] = function(n: integer): string
    return ("-- c\n"):rep(n * 1500) .. "local x = 1"
  end,
  ["declarations with comments"] = function(n: integer): string
    return ("-- c\n-- d\nlocal x = 1\n"):rep(n * 100)
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local small, large = Lexer.lex(form(15), "t.tl"), Lexer.lex(form(60), "t.tl")
    local ok, why = Speed.within(function()
      local _ = Parser.parse(small, "t.tl", "tl")
    end, function()
      local _ = Parser.parse(large, "t.tl", "tl")
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end
