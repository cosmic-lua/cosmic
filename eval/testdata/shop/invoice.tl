--- An invoice: a customer and the lines of what they bought.
---
--- Each line keeps the name the product had when it was added, so a later
--- change to the catalog does not change an invoice already made.

local Cash = require("money")
local Catalog = require("catalog")
local Text = require("text")

local record Invoice
  --- Who the invoice is for.
  record Customer
    name: string
    city: string
  end

  --- One line: what was bought, how many, and the price of one.
  record Line
    name: string
    qty: integer
    each: Cash.Amount
  end

  customer: Customer
  lines: mut {Line}
end

--- An invoice for `customer`, with no lines.
function Invoice.new(customer: Invoice.Customer): Invoice
  return { customer = customer, lines = {} }
end

--- Adds `qty` of `p` to `inv`, at the price `p` has now.
function Invoice.add(inv: Invoice, p: Catalog.Product, qty: integer)
  inv.lines[#inv.lines + 1] = { name = p.name, qty = qty, each = p.price }
end

--- What `line` comes to: its price times its quantity.
function Invoice.line_total(line: Invoice.Line): Cash.Amount
  return Cash.times(line.each, line.qty)
end

--- What all of `inv` comes to.
function Invoice.total(inv: Invoice): Cash.Amount
  local sum = Cash.of(0)
  for _, line in ipairs(inv.lines) do sum = Cash.add(sum, Invoice.line_total(line)) end
  return sum
end

--- `inv` with `percent` off each line, rounded down to the cent.
function Invoice.discount(inv: Invoice, percent: integer): Invoice
  local out = Invoice.new(inv.customer)
  for _, line in ipairs(inv.lines) do
    local each = Cash.of(line.each.cents * (100 - percent) // 100)
    out.lines[#out.lines + 1] = { name = line.name, qty = line.qty, each = each }
  end
  return out
end

--- `inv` as the text of a receipt: the customer's name and city, a line for
--- each line (quantity, name, the price of one, the line's total) and the total.
function Invoice.format(inv: Invoice): string
  local out: mut {string} = { inv.customer.name .. ", " .. inv.customer.city }
  for _, line in ipairs(inv.lines) do
    out[#out + 1] = string.format("%3d x %s %s %s", line.qty, Text.pad_right(line.name, 12),
      Text.pad_left(Cash.format(line.each), 7), Text.pad_left(Cash.format(Invoice.line_total(line)), 8))
  end
  out[#out + 1] = "total " .. Cash.format(Invoice.total(inv))
  return table.concat(out, "\n")
end

return Invoice
