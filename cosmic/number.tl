--- Number reads that answer an integer or say why not. `tonumber` and
--- `math.tointeger` answer nil, and a caller that has already checked the
--- text's shape (a `%d+` match, a hex group) then asserts or adds to a
--- nil; here such a caller reads the integer, and a text that is not one
--- raises with the text in the message. A text not checked yet, as a
--- command's argument, is read with [`read_integer`], which answers nil and
--- why instead.
---
---     local port = Number.integer("8080") -- 8080
---     local count, why = Number.read_integer("12x") -- nil, why

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

--- The integer `text` spells in `radix`, or nil and why: what
--- [`Number.integer`] reads, and [`Number.read_integer`] answers.
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
--- it is not 2 to 36.
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
--- wrapped as `tonumber(text, base)` wraps it. Raises, blaming its
--- caller, when `text` is not such an integer or `base` is not 2 to 36.
--- What a person typed or a request sent is read with
--- [`Number.read_integer`], which answers nil instead.
--- @param text string The digits to read
--- @param base integer | nil The radix, 2 to 36; 10 when nil
--- @return integer The value
function Number.integer(text: string, base?: integer): integer
  local value, why = read(text, radix_of(base))
  if value == nil then error(why, 2) end
  return value
end

--- The integer `text` spells, by [`Number.integer`]'s rule, or nil and
--- why where it spells none: for what a person typed or a request sent,
--- where `math.tointeger(tonumber(text))` would also take "0x10", "1e2"
--- and " 7". Raises, blaming its caller, only for a `base` that is not
--- 2 to 36, which is the program's fault.
---
---     local limit = Number.read_integer("20") -- 20
---     local none, why = Number.read_integer("1e2") -- nil, and why
--- @param text string The digits to read
--- @param base integer | nil The radix, 2 to 36; 10 when nil
--- @return integer | nil The value, or nil
--- @return string Why there is none, or ""
function Number.read_integer(text: string, base?: integer): integer?, string
  return read(text, radix_of(base))
end

return Number
