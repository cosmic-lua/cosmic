local Calc = require("eval.plant.calc")
local Test = require("cosmic.test")

local function test_sums_and_products()
  assert(Calc.eval("1+2") == 3)
  assert(Calc.eval("2*3+4") == 10)
  assert(Calc.eval("2+3*4") == 14)
end

local function test_parentheses_group()
  assert(Calc.eval("(1+2)*3") == 9)
  assert(Calc.eval(" ( 7 ) ") == 7)
end

local function test_a_power_and_a_division()
  assert(Calc.eval("2^3") == 8)
  assert(Calc.eval("9/2") == 4.5)
end

local function test_a_bad_text_raises()
  Test.raises(function() local _ = Calc.eval("1+") end)
end
