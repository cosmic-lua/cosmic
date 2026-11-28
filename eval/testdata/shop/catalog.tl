--- The products a shop sells, read from lines of `sku<TAB>name<TAB>price`.

local Money = require("money")

local record Catalog
  --- One product.
  record Product
    sku: string
    --- What the shelf label says, such as `green tea`.
    name: string
    price: Money.Amount
  end
end

--- The products of `text`, one a line, as `sku<TAB>name<TAB>price`; nil and the
--- number of the first line that is not one.
function Catalog.read(text: string): ({Catalog.Product}) | (nil, string)
  local products: mut {Catalog.Product} = {}
  local n = 0
  for line in text:gmatch("[^\n]+") do
    n = n + 1
    local sku, name, price = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)$")
    local amount = price and Money.parse(price)
    if sku == nil or name == nil or amount == nil then
      return nil, "line " .. tostring(n) .. " is not sku, name and price"
    end
    products[#products + 1] = { sku = sku, name = name, price = amount }
  end
  return products
end

--- The product of `sku` in `products`; nil where none has it.
function Catalog.find(products: {Catalog.Product}, sku: string): Catalog.Product?
  for _, p in ipairs(products) do
    if p.sku == sku then return p end
  end
  return nil
end

--- `p` on one line, as `sku name price`, such as `t1 green tea 3.50`.
function Catalog.format(p: Catalog.Product): string
  return p.sku .. " " .. p.name .. " " .. Money.format(p.price)
end

return Catalog
