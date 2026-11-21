--- Worked examples for [`cosmic.sign`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Codec = require("cosmic.codec")
local Rand = require("cosmic.rand")
local Sign = require("cosmic.sign")

local record Example
end

--- A new key pair: the seed is the secret to keep, the public key what
--- to hand out.
function Example.ed25519_public()
  local seed = assert(Rand.entropy(32))
  local public = Sign.ed25519_public(seed)
  print(#seed, #public)
  assert(#public == 32 and public == Sign.ed25519_public(seed))
end

--- Signing a message, with the seed of RFC 8032's first test vector: the
--- signature is 64 bytes whatever the message's length.
function Example.ed25519()
  local seed = assert(Codec.unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
  local signature = Sign.ed25519(seed, "")
  print(#signature, Codec.hex(signature):sub(1, 16))
  assert(Codec.hex(signature):sub(1, 16) == "e5564300c360ac72")
end

--- Checking a signature someone sent: any change to the message, the
--- signature or the key answers false, and so do bytes of the wrong
--- length.
function Example.ed25519_verify()
  local seed = assert(Rand.entropy(32))
  local public = Sign.ed25519_public(seed)
  local signature = Sign.ed25519(seed, "pay alice 5")
  assert(Sign.ed25519_verify(public, "pay alice 5", signature))
  assert(not Sign.ed25519_verify(public, "pay alice 500", signature))
  assert(not Sign.ed25519_verify(public, "pay alice 5", "not a signature"))
end

--- A new P-256 key pair, as an ACME account or a certificate takes
--- one: the secret is 32 bytes, the public point 65.
function Example.p256_secret()
  local secret = Sign.p256_secret()
  local public = Sign.p256_public(secret)
  print(#secret, #public)
  assert(#secret == 32 and #public == 65)
end

--- The public point splits into its coordinates, as a JSON Web Key
--- spells them.
function Example.p256_public()
  local public = Sign.p256_public(Sign.p256_secret())
  local x, y = public:sub(2, 33), public:sub(34, 65)
  print(Codec.base64url(x), Codec.base64url(y))
  assert(public:byte(1) == 4 and #x == 32 and #y == 32)
end

--- Signing with the key of RFC 6979 section A.2.5: the same secret and
--- message always give the same signature.
function Example.p256()
  local secret = assert(Codec.unhex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"))
  local signature = Sign.p256(secret, "sample")
  print(#signature, Codec.hex(signature):sub(1, 16))
  assert(Codec.hex(signature):sub(1, 16) == "efd48b2aacb6a8fd")
end

--- Checking a P-256 signature: a changed message, or bytes that are no
--- signature, answer false.
function Example.p256_verify()
  local secret = Sign.p256_secret()
  local public = Sign.p256_public(secret)
  local signature = Sign.p256(secret, "pay alice 5")
  assert(Sign.p256_verify(public, "pay alice 5", signature))
  assert(not Sign.p256_verify(public, "pay alice 500", signature))
  assert(not Sign.p256_verify(public, "pay alice 5", "not a signature"))
end

--- A new RSA key, for a peer that takes no P-256: the secret is a DER
--- RSAPrivateKey, and a 2048-bit key signs in 256 bytes.
function Example.rsa_secret()
  local secret = Sign.rsa_secret()
  local signature = Sign.rsa(secret, "message")
  print(#secret > 1000, #signature)
  assert(#signature == 256)
end

--- The public key is a DER RSAPublicKey: a SEQUENCE of the modulus and
--- the exponent, here 65537 in its last five bytes.
function Example.rsa_public()
  local public = Sign.rsa_public(Sign.rsa_secret())
  print(Codec.hex(public:sub(-5)))
  assert(public:byte(1) == 0x30 and Codec.hex(public:sub(-5)) == "0203010001")
end

--- Signing a message: the same key and message always give the same
--- signature.
function Example.rsa()
  local secret = Sign.rsa_secret()
  local signature = Sign.rsa(secret, "sample")
  print(#signature)
  assert(signature == Sign.rsa(secret, "sample"))
end

--- Checking an RSA signature: a changed message, or bytes that are no
--- signature, answer false.
function Example.rsa_verify()
  local secret = Sign.rsa_secret()
  local public = Sign.rsa_public(secret)
  local signature = Sign.rsa(secret, "pay alice 5")
  assert(Sign.rsa_verify(public, "pay alice 5", signature))
  assert(not Sign.rsa_verify(public, "pay alice 500", signature))
  assert(not Sign.rsa_verify(public, "pay alice 5", "not a signature"))
end

return Example
