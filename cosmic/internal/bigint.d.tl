-- Arithmetic on non-negative integers at the Lua boundary, as the core
-- provides it. A number is a big-endian byte string, of any number of
-- leading zero bytes, "" being zero. An answer has no leading zero byte,
-- and zero is one zero byte, except where a width is said. Every
-- function raises on an argument that is not a string or is longer than
-- its limit: `modulus_max` bytes for a modulus or an exponent,
-- `operand_max` for any other.
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

  -- The six below take a time fixed by their arguments' lengths and by
  -- the modulus, and answer at a fixed width. A modulus of zero raises.

  -- a mod modulus, in as many bytes as the modulus was given in.
  reduce: function(a: string, modulus: string): string
  -- (a + b) mod modulus, as wide as the modulus.
  addmod: function(a: string, b: string, modulus: string): string
  -- (a - b) mod modulus, as wide as the modulus.
  submod: function(a: string, b: string, modulus: string): string
  -- (a * b) mod modulus, as wide as the modulus. Raises on an even
  -- modulus.
  mulmod: function(a: string, b: string, modulus: string): string
  -- a * b in #a + #b bytes.
  product: function(a: string, b: string): string
  -- a + b in one byte more than the longer of a and b.
  sum: function(a: string, b: string): string
end

return bigint
