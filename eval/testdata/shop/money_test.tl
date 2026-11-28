local Money = require("money")

local function test_format_writes_two_decimals()
  assert(Money.format(Money.of(1234)) == "12.34")
  assert(Money.format(Money.of(5)) == "0.05")
  assert(Money.format(Money.of(-310)) == "-3.10")
end

local function test_add_and_times()
  assert(Money.add(Money.of(150), Money.of(-50)).cents == 100)
  assert(Money.times(Money.of(125), 4).cents == 500)
end
