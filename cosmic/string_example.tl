--- Examples for the cosmic.string module.
--- Demonstrates parsing text into integers with an honest refusal
--- instead of a silent truncation.

-- Example_to_integer demonstrates parsing an integer out of text.
-- The rule is the VALUE, not the spelling: an exponent or a hex prefix
-- naming an integral number parses, while a fractional one is refused
-- rather than truncated. The refusal is a plain nil + message, so a
-- default reads as `or <n>`.
local function Example_to_integer()
  local str = require("cosmic.string")
  -- parenthesized so the error slot does not spill into print
  print((str.to_integer("42")))
  print((str.to_integer("1e3")))
  print((str.to_integer("ff", 16)))
  local n, err = str.to_integer("7.5")
  print(n)
  print(err)
  print(str.to_integer("not a number") or 0)
  -- Output:
  -- 42
  -- 1000
  -- 255
  -- nil
  -- not an integer: "7.5"
  -- 0
end

-- Suppress unused warnings for examples
local _ = {Example_to_integer}
