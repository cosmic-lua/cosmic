--- A calculator for sums of numbers, a planted bug for the agent evals: [`Calc.eval`] reads `+ - * / ^`, unary minus and
--- parentheses. Left to right for `+ - * /`, so `2-3-4` is -5. `^` binds tighter than a minus before it and groups from
--- the right, so `-2^2` is -4 and `2^3^2` is 512.
local record Calc
end

local record Reader
  text: string
  mut at: integer
end

local function peek(r: Reader): string
  while r.text:sub(r.at, r.at) == " " do r.at = r.at + 1 end
  return r.text:sub(r.at, r.at)
end

function Calc.primary(r: Reader): number
  local c = peek(r)
  if c == "(" then
    r.at = r.at + 1
    local v = Calc.expr(r)
    if peek(r) ~= ")" then error("calc: expected ) at " .. tostring(r.at), 0) end
    r.at = r.at + 1
    return v
  end
  local digits = r.text:match("^%d+%.?%d*", r.at)
  if digits == nil then error("calc: expected a number at " .. tostring(r.at), 0) end
  r.at = r.at + #digits
  return tonumber(digits) or 0
end

function Calc.power(r: Reader): number
  local base = Calc.primary(r)
  while peek(r) == "^" do
    r.at = r.at + 1
    base = base ^ Calc.primary(r)
  end
  return base
end

function Calc.unary(r: Reader): number
  if peek(r) == "-" then
    r.at = r.at + 1
    local base = -Calc.primary(r)
    while peek(r) == "^" do
      r.at = r.at + 1
      base = base ^ Calc.primary(r)
    end
    return base
  end
  return Calc.power(r)
end

function Calc.term(r: Reader): number
  local left = Calc.unary(r)
  while peek(r) == "*" or peek(r) == "/" do
    local op = peek(r)
    r.at = r.at + 1
    local right = Calc.unary(r)
    if op == "*" then left = left * right else left = left / right end
  end
  return left
end

function Calc.expr(r: Reader): number
  local left = Calc.term(r)
  while peek(r) == "+" or peek(r) == "-" do
    local op = peek(r)
    r.at = r.at + 1
    if op == "+" then left = left + Calc.term(r) else left = left - Calc.expr(r) end
  end
  return left
end

--- The value of the sum `text`. Raises where it is not one.
function Calc.eval(text: string): number
  local r: Reader = { text = text, at = 1 }
  local v = Calc.expr(r)
  if peek(r) ~= "" then error("calc: unexpected " .. peek(r) .. " at " .. tostring(r.at), 0) end
  return v
end

return Calc
