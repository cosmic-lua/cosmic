--- Arithmetic on non-negative integers of thousands of bits, for the
--- protocols built on it: Diffie-Hellman, SRP, RSA by hand.
---
--- A number is a big-endian byte string, as those protocols send and
--- hash it. Leading zero bytes change nothing, and "" is zero. An answer
--- is the shortest such string: no leading zero byte, and one zero byte
--- for zero. [`Bigint.pad`] gives the fixed width a protocol hashes.
---
--- - [`Bigint.powmod`] is modular exponentiation.
--- - Four functions stand beside it in a protocol's formulas: they
---   multiply, add, subtract ([`Bigint.sub`] refuses a negative
---   difference) and reduce.
--- - [`Bigint.compare`] orders two numbers.
---
---     local shared = Bigint.powmod(their_public, my_secret, prime)
---
--- A number has a limit, so that input from a peer cannot ask for
--- unbounded work: a modulus or an exponent is at most
--- [`Bigint.modulus_bytes`] bytes (8192 bits), and any other operand at
--- most [`Bigint.operand_bytes`], twice that, so the product of two
--- numbers below a modulus can still be reduced. The limit counts the
--- bytes given, leading zeros included. A longer string raises, as does
--- an argument that is not a string: check the length of what a peer
--- sent before computing with it.
---
--- Secrets. The numbers are mbedtls's (the bignum its RSA and ECC use),
--- and only [`Bigint.powmod`] is written to hide a number: its time
--- does not depend on the value of the exponent, given the lengths of the
--- exponent and the modulus. It uses no blinding. Its time can tell how
--- many of the exponent's leading 8-byte words are zero, and whether the
--- base is below the modulus; a base that is not is first reduced by a
--- division whose time depends on it. So a secret exponent is safe to
--- pass, at the width its protocol fixes, with a base below the modulus.
--- Every other function takes a time that depends on its operands'
--- values, and so does the length of every answer. Compare secrets with
--- [`cosmic.hash.equal`] over [`Bigint.pad`], not [`Bigint.compare`].

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local raw = require("cosmic.internal.bigint")

local String = require("cosmic.string")

local record Bigint
  --- The most bytes of a modulus or an exponent: 1024, which is 8192
  --- bits.
  modulus_bytes: integer
  --- The most bytes of an operand that is neither a modulus nor an
  --- exponent: 2048.
  operand_bytes: integer
end

Bigint.modulus_bytes = raw.modulus_max
Bigint.operand_bytes = raw.operand_max

--- `base` to the power `exponent`, modulo `modulus`, which is odd: every
--- prime a protocol works modulo is, and so is an RSA modulus. Zero to
--- the power zero is one, and everything modulo one is zero. The time
--- taken does not depend on the exponent's value (the module's doc says
--- what it can tell). Raises on a modulus that is zero or even, and on a
--- number over its limit.
---
---     local public = Bigint.powmod(generator, secret, prime)
function Bigint.powmod(base: string, exponent: string, modulus: string): string
  return raw.powmod(base, exponent, modulus)
end

--- The product of `a` and `b`.
function Bigint.mul(a: string, b: string): string
  return raw.mul(a, b)
end

--- The sum of `a` and `b`.
function Bigint.add(a: string, b: string): string
  return raw.add(a, b)
end

--- `a` minus `b`, and "". nil and a message when `b` is the larger: a
--- byte string is never a negative number, and the difference does not
--- wrap. To subtract modulo `m`, add `m` to `a` first.
---
---     local difference = assert(Bigint.sub(Bigint.add(a, m), Bigint.mod(b, m)))
function Bigint.sub(a: string, b: string): string?, string
  return raw.sub(a, b)
end

--- `a` modulo `modulus`: the remainder, from zero to `modulus` less one.
--- Raises on a zero modulus.
function Bigint.mod(a: string, modulus: string): string
  return raw.mod(a, modulus)
end

--- -1, 0 or 1 as `a` is less than, equal to or greater than `b`, as
--- numbers: leading zero bytes do not count.
function Bigint.compare(a: string, b: string): integer
  return raw.compare(a, b)
end

--- `number` in exactly `width` bytes, zero bytes on the left, and "": the
--- form a protocol hashes or sends a number in. nil and a message when
--- the number needs more bytes than `width`. Zero fits in a width of 0,
--- as "". Raises on a negative width. It reads no limit: a string of any
--- length is a number here.
---
---     local sent = assert(Bigint.pad(public, #prime))
function Bigint.pad(number: string, width: integer): string?, string
  if width < 0 then error("bigint: pad's width must be 0 or more", 2) end
  local first = number:find("[^\0]")
  local digits = if first == nil then "" else number:sub(first) end
  if #digits > width then
    return nil, "bigint: the number needs " .. String.counted(#digits, "byte") .. ", more than " .. tostring(width)
  end
  return string.rep("\0", width - #digits) .. digits, ""
end

return Bigint
