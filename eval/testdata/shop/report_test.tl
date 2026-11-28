local Invoice = require("invoice")
local Money = require("money")
local Report = require("report")

local function test_the_most_spent_comes_first()
  local a = Invoice.new({ name = "Ada", city = "Leeds" })
  Invoice.add(a, { sku = "m3", name = "mug", price = Money.of(725) }, 1)
  local b = Invoice.new({ name = "Bo", city = "York" })
  Invoice.add(b, { sku = "t1", name = "green tea", price = Money.of(350) }, 3)
  assert(Report.format({ a, b }) == "Bo 10.50\nAda 7.25")
end
