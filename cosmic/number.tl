--- Number reads that answer an integer or say why not. `tonumber` and
--- `math.tointeger` answer nil with no reason and take "0x10", "1e2" and
--- " 7"; [`Number.integer`] takes only digits and answers a [`Failure`]
--- that names the text. A caller that has already checked the text's
--- shape (a `%d+` match, a hex group) asserts the answer.
---
---     local port = assert(Number.integer("8080")) -- 8080
---     local none, why = Number.integer("12x") -- nil, a Failure

local Failure = require("cosmic.failure")

local record Number
end

local DIGITS <const> = "0123456789abcdefghijklmnopqrstuvwxyz"

--- The value of the digit `char` in a base, or nil when `char` is no digit
--- of that base.
local function digit_value(char: string, base: integer): integer?
  local at = DIGITS:find(char:lower(), 1, true)
  if at == nil or at > base then return nil end
  return at - 1
end

--- The most digits any text of a base can have and still fit an integer:
--- base ^ n - 1 is at most `math.maxinteger`.
local function safe_digits(radix: integer): integer
  return math.floor(63 / math.log(radix, 2))
end

--- The integer `text` spells in `radix`, or nil and why in words.
local function read(text: string, radix: integer): integer?, string
  local negative = text:sub(1, 1) == "-"
  local first = if negative then 2 else 1 end
  if #text < first then
    return nil, ("number: integer of %q has no digits"):format(text)
  end
  -- A text of letters and digits with few enough digits to fit is `tonumber`'s to
  -- read: it refuses a digit past the base, and the loop below then says
  -- which. Anything else (space, "+", a long run) is the loop's alone.
  if #text - first + 1 <= safe_digits(radix) and text:find("^%-?%w+$") ~= nil then
    local whole = math.tointeger(tonumber(text, radix))
    if whole ~= nil then return whole, "" end
  end
  -- Built as a negative so that math.mininteger, whose magnitude no
  -- positive integer holds, reads like the rest.
  local value = 0
  for at = first, #text do
    local digit = digit_value(text:sub(at, at), radix)
    if digit == nil then
      return nil, ("number: integer of %q has %q at %d, which is no base %d digit"):format(
        text, text:sub(at, at), at, radix)
    end
    if value < (math.mininteger + digit + radix - 1) // radix then
      return nil, ("number: integer of %q is outside what an integer holds"):format(text)
    end
    value = value * radix - digit
  end
  if negative then return value, "" end
  if value == math.mininteger then
    return nil, ("number: integer of %q is outside what an integer holds"):format(text)
  end
  return -value, ""
end

--- `base`, or 10 where nil; raises, blaming the caller's caller, where
--- it is not 2 to 36, which is the program's fault.
local function radix_of(base?: integer): integer
  local radix = base or 10
  if radix < 2 or radix > 36 then
    error(("number: integer base %d is not 2 to 36"):format(radix), 3)
  end
  return radix
end

--- The integer `text` spells: an optional "-" and then one or more digits
--- of `base` (10 unless given, 2 to 36, letters in either case). No
--- space, "+" or "0x" prefix, fraction or exponent is part of it, and a
--- value past `math.mininteger` or `math.maxinteger` is refused rather than
--- wrapped as `tonumber(text, base)` wraps it. Any other text answers a
--- "parse" [`Failure`] that names the text and the place. Raises,
--- blaming its caller, only for a `base` that is not 2 to 36.
---
---     local limit = assert(Number.integer("20")) -- 20
---     local none, why = Number.integer("1e2") -- nil, and why
--- @param text string The digits to read
--- @param base integer | nil The radix, 2 to 36; 10 when nil
function Number.integer(text: string, base?: integer): (integer) | (nil, Failure)
  local value, why = read(text, radix_of(base))
  if value == nil then return nil, Failure.at(why, 1) end
  return value
end

return Number
