--- Amounts of money in whole cents, and the text of them.
---
--- [`Money.format`] writes an amount as `12.34`, and [`Money.parse`] reads
--- that text back. Nothing here rounds: an amount is always whole cents.

local record Money
  --- An amount, in cents: `1234` is 12.34.
  record Amount
    cents: integer
  end
end

--- An amount of `cents`.
function Money.of(cents: integer): Money.Amount
  return { cents = cents }
end

--- `a` as text with two decimals, such as `12.34` or `-0.05`.
function Money.format(a: Money.Amount): string
  local sign = if a.cents < 0 then "-" else "" end
  local c = math.abs(a.cents)
  return sign .. string.format("%d.%02d", c // 100, c % 100)
end

--- The amount that `text` writes, such as `12.34`, `7`, `0.5` or `-3.10`;
--- nil for text that is not one, such as `1.234` or `12,00`.
function Money.parse(text: string): Money.Amount?
  local sign, whole, frac = text:match("^(%-?)(%d+)%.?(%d*)$")
  if sign == nil or whole == nil or frac == nil or #frac > 2 then return nil end
  if frac == "" and text:sub(-1) == "." then return nil end
  local cents = math.tointeger(tonumber(whole))! * 100
  if #frac == 1 then
    cents = cents + math.tointeger(tonumber(frac))! * 10
  elseif #frac == 2 then
    cents = cents + math.tointeger(tonumber(frac))!
  end
  if sign == "-" then cents = -cents end
  return { cents = cents }
end

--- The sum of `a` and `b`.
function Money.add(a: Money.Amount, b: Money.Amount): Money.Amount
  return { cents = a.cents + b.cents }
end

--- `a` taken `n` times.
function Money.times(a: Money.Amount, n: integer): Money.Amount
  return { cents = a.cents * n }
end

return Money
