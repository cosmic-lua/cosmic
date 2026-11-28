--- A day's sales: what each customer spent, from the day's invoices.

local Invoice = require("invoice")
local M = require("money")

local record Report
end

--- What each customer of `invoices` spent, by name, summed over their invoices.
function Report.by_customer(invoices: {Invoice}): {string: M.Amount}
  local spent: mut {string: M.Amount} = {}
  for _, inv in ipairs(invoices) do
    local name = inv.customer.name
    spent[name] = M.add(spent[name] or M.of(0), Invoice.total(inv))
  end
  return spent
end

--- `invoices` as lines of `name spent`, most spent first, ties by name; the
--- amount is written as Money.format writes it.
function Report.format(invoices: {Invoice}): string
  local spent = Report.by_customer(invoices)
  local names: mut {string} = {}
  for name in pairs(spent) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean
    if spent[a]!.cents ~= spent[b]!.cents then return spent[a]!.cents > spent[b]!.cents end
    return a < b
  end)
  local lines: mut {string} = {}
  for _, name in ipairs(names) do lines[#lines + 1] = name .. " " .. M.format(spent[name]!) end
  return table.concat(lines, "\n")
end

return Report
