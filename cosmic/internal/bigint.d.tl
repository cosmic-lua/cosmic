-- Arithmetic on non-negative integers at the Lua boundary, as the core
-- provides it. A number is a big-endian byte string, of any number of
-- leading zero bytes, "" being zero; an answer has no leading zero byte,
-- and zero is one zero byte. Every function raises on an argument that
-- is not a string or is longer than its limit: `modulus_max` bytes for a
-- modulus or an exponent, `operand_max` for any other.
--- @kind binding

local record bigint
  -- The most bytes of an operand that is neither a modulus nor an
  -- exponent.
  operand_max: integer
  -- The most bytes of a modulus or an exponent.
  modulus_max: integer

  -- base^exponent mod modulus. Raises on a modulus that is zero or
  -- even.
  powmod: function(base: string, exponent: string, modulus: string): string
  mul: function(a: string, b: string): string
  add: function(a: string, b: string): string
  -- a - b and "", or nil and a message when b is the larger.
  sub: function(a: string, b: string): string?, string
  -- a mod modulus. Raises on a zero modulus.
  mod: function(a: string, modulus: string): string
  -- -1, 0 or 1 as a is less than, equal to or greater than b.
  compare: function(a: string, b: string): integer
end

return bigint
