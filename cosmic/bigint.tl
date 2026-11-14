--- Arithmetic on non-negative integers of thousands of bits, for the
--- protocols built on it: Diffie-Hellman, SRP, RSA by hand.
---
--- A number is a big-endian byte string, as those protocols send and
--- hash it. Leading zero bytes change nothing, and "" is zero. An answer
--- is the shortest such string: no leading zero byte, and one zero byte
--- for zero. [`Bigint.pad`] gives the fixed width a protocol hashes. The
--- functions for secrets answer at a fixed width themselves.
---
--- - [`Bigint.powmod`] is modular exponentiation.
--- - Four functions stand beside it in a protocol's formulas: they
---   multiply, add, subtract ([`Bigint.sub`] refuses a negative
---   difference) and reduce.
--- - Six more are that arithmetic for secrets, each in a time and at a
---   width that the lengths of its arguments fix: [`Bigint.mulmod`],
---   [`Bigint.addmod`], [`Bigint.submod`] and [`Bigint.reduce`] modulo a
---   public number, [`Bigint.product`] and [`Bigint.sum`] with no
---   modulus.
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
--- and two kinds of function hide a value.
---
--- [`Bigint.powmod`] hides its exponent. It calls the library's
--- exponentiation for a secret exponent, whose loop the library
--- documents as constant in time and which does the same work for every
--- exponent of one string length: leading zero bytes count, so pass a
--- secret exponent at the fixed width its protocol gives it. Two things
--- still show: a check of the exponent's size reads past its leading
--- zero 8-byte words, a few instructions each, and an exponent of no
--- bytes is answered at once. The library has no blinding to ask for.
--- Its modulus is public: the setup that depends on it divides. Its
--- base is public too: it is compared with the modulus, and reduced by
--- a division when it is not below it.
---
--- The six functions for secrets hide the values of their operands, the
--- modulus excepted. Each does the same work for every operand of one
--- string length, leading zero bytes counted, and answers a string
--- whose length the arguments' lengths fix, so neither the time nor the
--- answer's length says anything of a value. Between reading the bytes
--- and writing them, they call only what the library documents as
--- constant in time in its operands' values (a multiplication by one
--- word added in, a subtraction, Montgomery's multiplication and a
--- conditional copy), and decide nothing by a value themselves. That
--- rests on the library's documentation and on reading the code, not on
--- a measurement, and nothing checks the instructions a compiler made
--- of it. They work in memory that is wiped before it is freed. What
--- still shows: the length of each argument, the modulus (how many
--- bytes it has past its leading zero ones, and whether it is even),
--- and whether the call raised.
---
--- Nothing else is hidden. [`Bigint.mul`], [`Bigint.add`],
--- [`Bigint.sub`], [`Bigint.mod`] and [`Bigint.compare`] take a time
--- that depends on their operands' values. The length of a shortest
--- answer shows how many leading zero bytes its number had, and every
--- answer is an ordinary string, which nothing wipes. Compare secrets
--- with [`cosmic.hash.equal`] over strings of one width, not
--- [`Bigint.compare`].

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
--- taken hides the exponent's value and nothing else (the module's doc
--- says what shows). Raises on a modulus that is zero or even, and on a
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
--- wrap. To subtract modulo `m`, add `m` to `a` first, or use
--- [`Bigint.submod`].
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

--- `a` modulo `modulus`, for a secret `a`: the remainder in exactly as
--- many bytes as `modulus` has, zero bytes on the left. The time taken
--- depends on the length of `a` and on the modulus, not on the value of
--- `a` (the module's doc says what shows). It takes longer than
--- [`Bigint.mod`], a step for each bit of `a`. Raises on a zero modulus
--- and on a number over its limit.
---
---     local digit = Bigint.reduce(hashed, order)
function Bigint.reduce(a: string, modulus: string): string
  return raw.reduce(a, modulus)
end

--- `a` plus `b`, modulo `modulus`, for secret operands: the sum in
--- exactly as many bytes as `modulus` has. Either operand may be any
--- number within its limit, at or above the modulus too. The time taken
--- depends on the lengths of `a` and `b` and on the modulus, not on
--- their values. Raises on a zero modulus and on a number over its
--- limit.
function Bigint.addmod(a: string, b: string, modulus: string): string
  return raw.addmod(a, b, modulus)
end

--- `a` minus `b`, modulo `modulus`, for secret operands: the difference
--- in exactly as many bytes as `modulus` has, the modulus added back
--- when `b` is the larger, so nothing is refused. The operands, the time
--- taken and the raises are [`Bigint.addmod`]'s.
---
---     local base = Bigint.submod(their_public, masked, prime)
function Bigint.submod(a: string, b: string, modulus: string): string
  return raw.submod(a, b, modulus)
end

--- `a` times `b`, modulo `modulus`, which is odd, for secret operands:
--- the product in exactly as many bytes as `modulus` has. The operands
--- and the time taken are [`Bigint.addmod`]'s. Raises on a modulus that
--- is zero or even, and on a number over its limit.
---
---     local masked = Bigint.mulmod(multiplier, verifier, prime)
function Bigint.mulmod(a: string, b: string, modulus: string): string
  return raw.mulmod(a, b, modulus)
end

--- `a` times `b`, for secret operands, where no modulus applies: the
--- product in exactly `#a + #b` bytes, zero bytes on the left. The time
--- taken depends on the two lengths, not on the values, so pass each
--- secret at the fixed width its protocol gives it. The product of two
--- long operands is longer than [`Bigint.operand_bytes`], and then no
--- function here takes it. Raises on a number over its limit.
function Bigint.product(a: string, b: string): string
  return raw.product(a, b)
end

--- `a` plus `b`, for secret operands, where no modulus applies: the sum
--- in exactly one byte more than the longer of `a` and `b` has, which
--- always holds it. The time taken depends on the two lengths, not on
--- the values. Raises on a number over its limit.
---
---     local exponent = Bigint.sum(a, Bigint.product(u, x))
function Bigint.sum(a: string, b: string): string
  return raw.sum(a, b)
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
--- length is a number here, and the answer is `width` bytes however
--- large, so `width` is the caller's own and never a peer's.
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
