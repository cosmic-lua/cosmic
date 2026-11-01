--- The speed of the lowering ([`lang.declarations`]), held to ratios and never to a clock: four times the
--- declarations costs about four times the time, for each form of the tree's own that could cost more than its
--- length: a union of many records told apart by a tag (the syntax tree's `Node`), a record that lists an
--- interface of many parents, a record of many fields, and aliases that name each other.
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- `source` parsed and scoped, to lower again and again.
local function prepare(source: string): Declarations.Input
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
  local first = parsed.errors[1]
  assert(#parsed.errors == 0, if first ~= nil then first.msg else "" end)
  local scoped = Scopes.build(parsed.chunk, "t.tl", {})
  return { module = "t", filename = "t.tl", chunk = parsed.chunk, scoped = scoped, dialect = "tl" }
end

local function lower(input: Declarations.Input)
  local result = Declarations.new():lower(input)
  local first = result.errors[1]
  assert(#result.errors == 0, if first ~= nil then first.msg else "" end)
end

local FORMS <const>: {string: function(n: integer): string} = {
  ["a union of tagged records"] = function(n: integer): string
    local out: mut {string} = {}
    local members: mut {string} = {}
    for i = 1, n * 20 do
      out[#out + 1] = "local enum K" .. tostring(i) .. " \"k" .. tostring(i) .. "\" end\nlocal record R" .. tostring(i) .. "\n  kind: K" .. tostring(i) ..
        "\n  value: integer\nend\n"
      members[i] = "R" .. tostring(i)
    end
    out[#out + 1] = "local type Any = " .. table.concat(members, " | ") .. "\n"
    return table.concat(out)
  end,
  ["a record that lists an interface of many parents"] = function(n: integer): string
    local out: mut {string} = {}
    local parents: mut {string} = {}
    for i = 1, n * 20 do
      out[#out + 1] = "local interface I" .. tostring(i) .. "\n  f" .. tostring(i) .. ": integer\nend\n"
      parents[i] = "I" .. tostring(i)
    end
    out[#out + 1] = "local interface Wide is " .. table.concat(parents, ", ") .. "\nend\n"
    out[#out + 1] = "local record R is Wide\n"
    for i = 1, n * 20 do
      out[#out + 1] = "  f" .. tostring(i) .. ": integer\n"
    end
    out[#out + 1] = "end\n"
    return table.concat(out)
  end,
  ["a record of many fields"] = function(n: integer): string
    local out: mut {string} = { "local record R\n" }
    for i = 1, n * 50 do
      out[#out + 1] = "  f" .. tostring(i) .. ": {string: integer}\n"
    end
    out[#out + 1] = "end\n"
    return table.concat(out)
  end,
  ["aliases that name each other"] = function(n: integer): string
    local out: mut {string} = { "local type A0 = integer\n" }
    for i = 1, n * 20 do
      out[#out + 1] = "local type A" .. tostring(i) .. " = {A" .. tostring((i - 1)) .. "}\n"
    end
    return table.concat(out)
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local small = prepare(form(5))
    local large = prepare(form(20))
    local ok, why = Speed.within(function()
      lower(small)
    end, function()
      lower(large)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end
