--- Tests of [`lang.truthy`]: the expressions the rule takes as neither false nor nil from their syntax, and those it leaves
--- to a function called on the spot.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Test = require("cosmic.test")
local Truthy = require("lang.truthy")

Test.policy{}

--- The expression `text` is, read in the new grammar.
local function expression(text: string): Ast.Exp
  local parsed = Parser.parse(Lexer.lex("return " .. text .. "\n", "t.tl"), "t.tl", "tl")
  assert(#parsed.errors == 0, text)
  local stat = parsed.chunk.body.stats[1]
  assert(stat is Ast.Return, text)
  return (assert(stat.values[1], text))
end

local record Case
  text: string
  never_false: boolean
end

local CASES <const>: {Case} = {
  { text = "1", never_false = true },
  { text = "1.5", never_false = true },
  { text = "\"s\"", never_false = true },
  { text = "{}", never_false = true },
  { text = "function() end", never_false = true },
  { text = "true", never_false = true },
  { text = "false", never_false = false },
  { text = "nil", never_false = false },
  { text = "-a", never_false = true },
  { text = "#a", never_false = true },
  { text = "~a", never_false = true },
  { text = "not a", never_false = false },
  { text = "(1)", never_false = true },
  { text = "((a))", never_false = false },
  { text = "a", never_false = false },
  { text = "a.b", never_false = false },
  { text = "f()", never_false = false },
  -- a cast is no value: it is as true as what it casts
  { text = "1 as integer", never_false = true },
  { text = "(\"s\" as string)", never_false = true },
  { text = "{} as {any: any}", never_false = true },
  { text = "{} as {string}", never_false = true },
  { text = "function() end as function(): integer", never_false = true },
  { text = "a as string", never_false = false },
  { text = "a as integer", never_false = false },
  { text = "a as {string}", never_false = false },
  { text = "a as {any: any}", never_false = false },
  { text = "a as function(): integer", never_false = false },
  { text = "f() as string", never_false = false },
  { text = "a as any", never_false = false },
  { text = "nil as string?", never_false = false },
  { text = "false as boolean", never_false = false },
  { text = "true as boolean", never_false = true },
  { text = "(a as string) as string", never_false = false },
  { text = "a == b", never_false = false },
  { text = "a and b", never_false = false },
  { text = "a or 1", never_false = false },
}

--- The operators that answer a number or a string, each a never-false expression whatever its operands, and those that
--- answer a boolean or one of their operands.
local ARITHMETIC <const>: {string} = { "+", "-", "*", "/", "//", "%", "^", "..", "&", "|", "~", "<<", ">>" }
local OTHERS <const>: {string} = { "<", "<=", ">", ">=", "==", "~=", "and", "or" }

local function test_an_expression_is_never_false_by_its_syntax()
  for _, c in ipairs(CASES) do
    assert(Truthy.never_false(expression(c.text)) == c.never_false, c.text)
  end
end

local function test_every_arithmetic_operator_answers_a_number_or_a_string_and_no_other_does()
  for _, op in ipairs(ARITHMETIC) do
    assert(Truthy.never_false(expression("a " .. op .. " b")), op)
  end
  for _, op in ipairs(OTHERS) do
    assert(not Truthy.never_false(expression("a " .. op .. " b")), op)
  end
end

local function test_the_cases_hold_both_answers()
  local yes, no = 0, 0
  for _, c in ipairs(CASES) do
    if c.never_false then yes = yes + 1 else no = no + 1 end
  end
  assert(yes >= 15 and no >= 15, tostring(yes) .. " " .. tostring(no))
end
