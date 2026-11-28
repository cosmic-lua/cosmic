local Catalog = require("catalog")
local Invoice = require("invoice")
local Money = require("money")

local TEA: Catalog.Product = { sku = "t1", name = "green tea", price = Money.of(350) }

local function test_a_line_keeps_the_name_it_was_added_with()
  local inv = Invoice.new({ name = "Ada", city = "Leeds" })
  Invoice.add(inv, TEA, 2)
  assert(inv.lines[1]!.label == "green tea")
  assert(inv.customer.name == "Ada")
  assert(Invoice.total(inv).cents == 700)
end

local function test_a_discount_rounds_down()
  local inv = Invoice.new({ name = "Bo", city = "York" })
  Invoice.add(inv, TEA, 1)
  local off = Invoice.discount(inv, 15)
  assert(off.lines[1]!.each.cents == 297)
  assert(off.lines[1]!.label == "green tea")
end
