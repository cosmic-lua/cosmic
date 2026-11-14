--- Worked examples for [`cosmic.bigint`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Bigint = require("cosmic.bigint")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Rand = require("cosmic.rand")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local record Example end

--- The 2048-bit prime of RFC 3526 (group 14), whose generator is 2.
local prime = assert(Codec.unhex(
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aacaa68ffffffffffffffff"
))

--- Whether `public`, as a peer sent it, is a value to compute with:
--- short enough to be a number here, and from 2 to the prime less 2, so
--- that the shared secret is not one the peer chose.
local function acceptable(public: string): boolean
  if #public > Bigint.modulus_bytes then return false end
  local below = assert(Bigint.sub(prime, "\1"))
  return Bigint.compare(public, "\1") > 0 and Bigint.compare(public, below) < 0
end

--- A Diffie-Hellman exchange: each side sends the generator to the power
--- of its secret, and raises what it received to the same power. Both
--- arrive at one number, which neither sent. The secret exponents are 32
--- bytes from the operating system, passed at that fixed width.
function Example.powmod()
  local generator = "\2"
  local alice_secret = assert(Rand.entropy(32))
  local bob_secret = assert(Rand.entropy(32))
  local alice_public = Bigint.powmod(generator, alice_secret, prime)
  local bob_public = Bigint.powmod(generator, bob_secret, prime)
  assert(acceptable(alice_public) and acceptable(bob_public))
  local alice_shared = Bigint.powmod(bob_public, alice_secret, prime)
  local bob_shared = Bigint.powmod(alice_public, bob_secret, prime)
  assert(alice_shared == bob_shared)
  assert(not acceptable("\1") and not acceptable(prime))
end

--- A number at the width its protocol hashes it in: as many bytes as
--- the modulus, however small the number.
function Example.pad()
  local public = Bigint.powmod("\2", "\10", prime)
  print(Codec.hex(public))
  local padded = assert(Bigint.pad(public, #prime))
  print(#padded, Codec.hex(padded:sub(-3)))
  local narrow, why = Bigint.pad(public, 1)
  print(narrow, why)
  assert(public == "\4\0" and #padded == 256 and narrow == nil)
end

--- Arithmetic modulo `m` from the four plain operations: a product is
--- reduced, and a subtraction adds `m` first so that it never goes
--- below zero.
function Example.sub()
  local m = "\101"
  local a, b = "\7", "\200"
  local product = Bigint.mod(Bigint.mul(a, b), m)
  local difference = Bigint.mod(assert(Bigint.sub(Bigint.add(a, m), Bigint.mod(b, m))), m)
  print(product:byte(), difference:byte())
  assert(product == "\87" and difference == "\9")
  local negative, why = Bigint.sub(a, b)
  assert(negative == nil and why == "bigint: the difference is negative")
end

--- The same arithmetic on secrets: the modulus is the last argument,
--- nothing is added before a subtraction, and each answer is as wide as
--- the modulus, so neither the time taken nor an answer's length says
--- anything of a value.
function Example.submod()
  local m = "\0\101"
  local a, b = "\7", "\200"
  local difference = Bigint.submod(a, b, m)
  local back = Bigint.addmod(difference, b, m)
  print(#difference, difference:byte(-1), back:byte(-1))
  assert(difference == "\0\9" and back == "\0\7")
end

--- A value blinded and unblinded, as a protocol hides one in transit:
--- multiplied by a mask modulo the prime, then by the mask's inverse,
--- which Fermat gives as the mask to the power of the prime less 2.
function Example.mulmod()
  local value = assert(Rand.entropy(32))
  local mask = assert(Rand.entropy(#prime))
  local blinded = Bigint.mulmod(value, mask, prime)
  local inverse = Bigint.powmod(mask, assert(Bigint.sub(prime, "\2")), prime)
  local unblinded = Bigint.mulmod(blinded, inverse, prime)
  assert(#blinded == #prime)
  assert(unblinded == assert(Bigint.pad(value, #prime)))
end

--- A number below a modulus from a hash wider than it, as a signature
--- scheme derives a secret scalar: the 64 bytes are reduced whole, with
--- none cut off, and the scalar is as wide as the modulus whatever its
--- value.
function Example.reduce()
  local order = assert(Codec.unhex("ffffffffffffffffffffffffffffffffbaaedce6af48a03bbfd25e8cd0364141"))
  local wide = Hash.digest("sha512", "a seed that is kept secret")
  local scalar = Bigint.reduce(wide, order)
  print(#wide, #scalar)
  assert(#scalar == #order and Bigint.compare(scalar, order) < 0)
end

--- A secret split into two shares, neither of which says anything of
--- it alone: one is drawn, the other is the secret less it, and their
--- sum modulo the prime is the secret again, at the prime's width.
function Example.addmod()
  local secret = assert(Rand.entropy(32))
  local first = assert(Rand.entropy(#prime))
  local second = Bigint.submod(secret, first, prime)
  local joined = Bigint.addmod(first, second, prime)
  assert(#second == #prime)
  assert(joined == assert(Bigint.pad(secret, #prime)))
end

--- An exponent that is the sum of two secret exponents, where no
--- modulus applies: a power of it is the product of the two powers. The
--- sum is one byte wider than the wider exponent, whatever its value,
--- as [`Bigint.powmod`] asks of a secret exponent.
function Example.sum()
  local a, b = assert(Rand.entropy(32)), assert(Rand.entropy(48))
  local exponent = Bigint.sum(a, b)
  print(#exponent)
  local together = Bigint.powmod("\2", exponent, prime)
  local apart = Bigint.mulmod(Bigint.powmod("\2", a, prime), Bigint.powmod("\2", b, prime), prime)
  assert(#exponent == 49 and apart == assert(Bigint.pad(together, #prime)))
end

--- An exponent that is a product and a sum of secrets, as SRP's client
--- raises to `a + u*x`: the product is as wide as `u` and `x` together,
--- so the exponent's width is fixed by the three lengths.
function Example.product()
  local a = assert(Rand.entropy(64))
  local u, x = Hash.digest("sha256", "public values"), Hash.digest("sha256", "salt and password")
  local scaled = Bigint.product(u, x)
  local exponent = Bigint.sum(a, scaled)
  print(#scaled, #exponent)
  local shared = Bigint.powmod("\2", exponent, prime)
  -- g^(a + u*x) is g^a * (g^u)^x.
  local scrambled = Bigint.powmod(Bigint.powmod("\2", u, prime), x, prime)
  local parts = Bigint.mulmod(Bigint.powmod("\2", a, prime), scrambled, prime)
  assert(#scaled == 64 and #exponent == 65 and parts == assert(Bigint.pad(shared, #prime)))
end

--- The two limits: the product of two numbers of a modulus's length is
--- still an operand, so it can be reduced.
function Example.operand_bytes()
  local largest = string.rep("\255", Bigint.modulus_bytes)
  local product = Bigint.mul(largest, largest)
  print(Bigint.modulus_bytes, Bigint.operand_bytes, #product)
  assert(#product == Bigint.operand_bytes)
  assert(Bigint.mod(product, largest) == "\0")
end

return Example
