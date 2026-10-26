--- The speed of [`build.fix.format`], held to ratios and never to a clock ([`lang.speed`]): a slow machine slows
--- every side of a ratio alike. Formatting a source (lexing, parsing and laying it out, reading the layout back and
--- comparing the two, and laying it out once more to see it is a fixed point) costs a small multiple of lexing and
--- parsing it, and four times the input costs about four times the time, for each form that could cost more than its
--- length.
local Fs = require("cosmic.fs")
local Format = require("build.fix.format")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{
  grants = { { path = "lang/lexer.tl", letters = "r" } },
}

--- How many times the cost of lexing and parsing a source that formatting it may cost. Formatting parses the source four
--- times (the layout, the reads of the source and of its layout, and the layout of that layout), writes two layouts
--- and compares two trees; it costs about 25 times lexing and parsing it once, and this allows twice that.
local BUDGET <const>: integer = 50

--- The statements of a program of the grammar, to repeat.
local SAMPLE <const> = [[
-- A counter.
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
local t = {
  a = 1,
  b = f(x,
    y),
}
]]

--- The cost of formatting `source`, which must be formatted, against lexing and parsing it.
local function formatting_within(source: string, limit: integer): boolean, string
  assert(Format.format(source, "t.tl").text ~= nil, "the source is formatted")
  return Speed.within(function()
    local _ = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
  end, function()
    local _ = Format.format(source, "t.tl")
  end, limit)
end

local function test_formatting_a_large_module_of_the_tree_costs_a_small_multiple_of_parsing_it()
  local source = assert(Fs.read("lang/lexer.tl"))
  assert(#source > 30000, "the module is large")
  local ok, why = formatting_within(source, BUDGET)
  assert(ok, "formatting " .. why)
end

local function test_formatting_a_program_costs_a_small_multiple_of_parsing_it()
  local ok, why = formatting_within(SAMPLE:rep(60), BUDGET)
  assert(ok, "formatting " .. why)
end

--- Forms that a formatter could make slower than their length, each as a function of how many to write.
local FORMS <const>: {string: function(n: integer): string} = {
  statements = function(n: integer): string return SAMPLE:rep(n) end,
  ["a left-associative chain"] = function(n: integer): string
    return "local x = a" .. (" + a"):rep(n * 100) .. "\n"
  end,
  ["a chain that breaks before each operator"] = function(n: integer): string
    return "local x = a" .. ("\n  + a"):rep(n * 50) .. "\n"
  end,
  ["a table"] = function(n: integer): string
    return "local x = {\n" .. ("  1, k = 2, [3] = f(),\n"):rep(n * 20) .. "}\n"
  end,
  ["an argument list"] = function(n: integer): string
    return "f(" .. ("a,\n  "):rep(n * 50) .. "a)\n"
  end,
  ["an elseif chain"] = function(n: integer): string
    return "if a then b() " .. ("elseif c then d() "):rep(n * 25) .. "end\n"
  end,
  ["a record"] = function(n: integer): string
    local fields: mut {string} = {}
    for i = 1, n * 25 do fields[#fields + 1] = "f" .. tostring(i) .. ": integer\n" end
    return "local record R\n" .. table.concat(fields) .. "end\n"
  end,
  ["a match"] = function(n: integer): string
    return "match f() do\n" .. ("| (true, v) then g(v)\n"):rep(n * 15) .. "end\n"
  end,
  ["blocks on one line"] = function(n: integer): string
    return ("if a then b() end if c then d() else e() end for i = 1, 2 do f() end\n"):rep(n * 10)
  end,
  ["blocks to open"] = function(n: integer): string
    return ("if a then b() c() end while d do e() f() end\n"):rep(n * 10)
  end,
  ["blocks one in the other"] = function(n: integer): string
    return ("do "):rep(n * 2) .. "x = 1 " .. ("end "):rep(n * 2) .. "\n"
  end,
  ["a run of comments"] = function(n: integer): string
    return ("-- c\n"):rep(n * 500) .. "local x = 1\n"
  end,
  ["declarations with comments"] = function(n: integer): string
    return ("-- c\n--- d\nlocal x = 1 -- e\n"):rep(n * 100)
  end,
}

--- Asserts that four times the input costs at most ten times the time for each of the forms `names`.
local function scales(names: {string})
  for _, name in ipairs(names) do
    local form = FORMS[name]
    assert(form ~= nil, name .. " is a form")
    local small, large = form(4), form(16)
    assert(Format.format(small, "t.tl").text ~= nil and Format.format(large, "t.tl").text ~= nil, name .. " is formatted")
    local ok, why = Speed.within(function()
      local _ = Format.format(small, "t.tl")
    end, function()
      local _ = Format.format(large, "t.tl")
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end

local function test_four_times_the_statements_cost_about_four_times_the_time()
  scales({ "statements", "declarations with comments" })
end

local function test_four_times_the_blocks_cost_about_four_times_the_time()
  scales({ "blocks on one line", "blocks to open", "blocks one in the other" })
end

local function test_four_times_the_entries_cost_about_four_times_the_time()
  scales({ "a table", "a match", "an elseif chain", "a record" })
end

local function test_four_times_the_operators_arguments_and_comments_cost_about_four_times_the_time()
  scales({ "a left-associative chain", "a chain that breaks before each operator", "an argument list", "a run of comments" })
end
