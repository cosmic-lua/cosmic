--- The speed of the checker ([`lang.check`]), held to ratios and never to a clock: four times the input costs about four
--- times the time, for each shape that could cost more than its length: a chain of operators, a record of many fields
--- read many times and given in a literal, a literal of many items, a union of many tagged records read by a field
--- they share, an `if` expression of many arms, and a function of many parameters called with all of them.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{}

--- `source` lowered into a program, to check again and again.
local record Prepared
  program: Declarations.Program
  input: Declarations.Input
  lowered: Declarations.Lowered
end

local function prepare(source: string): Prepared
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0, parsed.errors[1] and parsed.errors[1].msg or "")
  local scoped = Scopes.build(parsed.chunk, "t.tl", {})
  local program = Declarations.new()
  local input: Declarations.Input = { module = "t", filename = "t.tl", chunk = parsed.chunk, scoped = scoped, dialect = "tl" }
  local lowered = program:lower(input)
  assert(#lowered.errors == 0 and #scoped.errors == 0, lowered.errors[1] and lowered.errors[1].msg or "")
  return { program = program, input = input, lowered = lowered }
end

local function check(p: Prepared)
  local result = Check.check(p.program, p.input, p.lowered)
  assert(#result.errors == 0, result.errors[1] and result.errors[1].msg or "")
end

local FORMS <const>: {string: function(n: integer): string} = {
  ["a chain of operators"] = function(n: integer): string
    local terms: mut {string} = {}
    for i = 1, n * 50 do
      terms[i] = "a"
    end
    return "local a: integer = 1\nlocal b: integer = " .. table.concat(terms, " + ") .. "\n"
  end,
  ["a record of many fields read and given"] = function(n: integer): string
    local out: mut {string} = { "local record R\n" }
    local given: mut {string} = {}
    local reads: mut {string} = {}
    for i = 1, n * 30 do
      out[#out + 1] = "  f" .. i .. ": integer\n"
      given[i] = "f" .. i .. " = " .. i
      reads[i] = "local v" .. i .. ": integer = r.f" .. i .. "\n"
    end
    out[#out + 1] = "end\nlocal r: R = { " .. table.concat(given, ", ") .. " }\n" .. table.concat(reads)
    return table.concat(out)
  end,
  ["a literal of many items"] = function(n: integer): string
    local items: mut {string} = {}
    for i = 1, n * 100 do
      items[i] = tostring(i)
    end
    return "local xs: {integer} = { " .. table.concat(items, ", ") .. " }\nlocal ys = { " .. table.concat(items, ", ") .. " }\n"
  end,
  ["a union of many tagged records read by a shared field"] = function(n: integer): string
    local out: mut {string} = {}
    local members: mut {string} = {}
    for i = 1, n * 8 do
      out[#out + 1] = "local enum K" .. i .. " \"k" .. i .. "\" end\nlocal record R" .. i .. "\n  kind: K" .. i ..
        "\n  value: integer\nend\n"
      members[i] = "R" .. i
    end
    out[#out + 1] = "local type Any = " .. table.concat(members, " | ") .. "\nlocal function f(a: Any): integer\n"
    for i = 1, n * 8 do
      out[#out + 1] = "  local v" .. i .. ": integer = a.value\n"
    end
    out[#out + 1] = "  return a.value\nend\n"
    return table.concat(out)
  end,
  ["an if expression of many arms"] = function(n: integer): string
    local arms: mut {string} = {}
    for i = 1, n * 50 do
      arms[i] = (if i == 1 then "if" else "elseif" end) .. " b then " .. i
    end
    return "local b: boolean = true\nlocal x: integer = " .. table.concat(arms, " ") .. " else 0 end\n"
  end,
  ["a function of many parameters called with all of them"] = function(n: integer): string
    local params: mut {string} = {}
    local args: mut {string} = {}
    for i = 1, n * 30 do
      params[i] = "p" .. i .. ": integer"
      args[i] = tostring(i)
    end
    return "local function f(" .. table.concat(params, ", ") .. "): integer\n  return p1\nend\nlocal x: integer = f(" ..
      table.concat(args, ", ") .. ")\n"
  end,
}

--- Holds each of `names` to four times the input costing about four times the time.
local function hold(names: {string})
  for _, name in ipairs(names) do
    local form = FORMS[name]
    local small = prepare(form(5))
    local large = prepare(form(20))
    local ok, why = Speed.within(function()
      check(small)
    end, function()
      check(large)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_chain_a_record_and_a_literal()
  hold({ "a chain of operators", "a record of many fields read and given", "a literal of many items" })
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_union_an_if_expression_and_a_call()
  hold({ "a union of many tagged records read by a shared field", "an if expression of many arms",
    "a function of many parameters called with all of them" })
end
