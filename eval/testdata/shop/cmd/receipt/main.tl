--- Prints the receipts of the day's sample orders, then the day's report.

local Catalog = require("catalog")
local Invoice = require("invoice")
local Report = require("report")

--- One order: who placed it, as `name,city`, and each sku with how many.
local record Order
  who: string
  picks: {Pick}
end

--- A sku and how many of it.
local record Pick
  sku: string
  qty: integer
end

local PRODUCTS <const> = "t1\tgreen tea\t3.50\nc2\tcoffee beans\t12.00\nm3\tmug\t7.25\nh4\thoney\t5.05\n"

return function(_argv: {string}): integer
  local products = assert(Catalog.read(PRODUCTS))
  local orders: {Order} = {
    { who = "Ada,Leeds", picks = { { sku = "t1", qty = 2 }, { sku = "m3", qty = 1 } } },
    { who = "Bo,York", picks = { { sku = "c2", qty = 1 }, { sku = "h4", qty = 3 } } },
    { who = "Ada,Leeds", picks = { { sku = "h4", qty = 1 } } },
  }
  local invoices: mut {Invoice} = {}
  for _, order in ipairs(orders) do
    local name, city = order.who:match("^([^,]+),(.+)$")
    local inv = Invoice.new({ name = assert(name), city = assert(city) })
    for _, pick in ipairs(order.picks) do
      Invoice.add(inv, assert(Catalog.find(products, pick.sku)), pick.qty)
    end
    print(Invoice.format(inv))
    print("")
    invoices[#invoices + 1] = inv
  end
  print(Report.format(invoices))
  return 0
end
