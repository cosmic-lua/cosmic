--- Signatures over raw bytes: a holder of a secret signs a message, and
--- anyone with the public key checks the signature. [`Codec.hex`] and
--- [`Codec.base64`] spell a key or a signature for a person or a format.
--- Two schemes are here: Ed25519 (RFC 8032), and ECDSA over the NIST
--- curve P-256 with SHA-256, which JOSE calls ES256 (RFC 7518) and which
--- certificate authorities and ACME servers take where they take no
--- Ed25519.
---
--- - [`Sign.ed25519_public`] is the public key of a seed.
--- - [`Sign.ed25519`] signs a message under a seed.
--- - [`Sign.ed25519_verify`] checks a signature, and is safe to give
---   bytes from anyone.
--- - [`Sign.p256_secret`] draws a new P-256 secret.
--- - [`Sign.p256_public`] is the public point of a P-256 secret.
--- - [`Sign.p256`] signs a message under a P-256 secret.
--- - [`Sign.p256_verify`] checks a P-256 signature, and is safe to give
---   bytes from anyone.
---
---     local seed = assert(Rand.entropy(32))
---     local public = Sign.ed25519_public(seed)
---     local signature = Sign.ed25519(seed, "message")
---     assert(Sign.ed25519_verify(public, "message", signature))
---
--- The seed is the whole secret, RFC 8032's 32-byte private key: draw it
--- from [`Rand.entropy`], never from a password or a seeded generator.
--- Signing is deterministic: a seed and a message always give the same
--- signature. This is pure Ed25519, over the message itself; the
--- prehashed and context variants (Ed25519ph, Ed25519ctx) are not here.
---
---     local secret = Sign.p256_secret()
---     local public = Sign.p256_public(secret)
---     local signature = Sign.p256(secret, "message")
---     assert(Sign.p256_verify(public, "message", signature))
---
--- A P-256 secret is a scalar from 1 to the group order n less 1, as 32
--- big-endian bytes: draw it with [`Sign.p256_secret`], since 32 bytes
--- from [`Rand.entropy`] fall outside that range about once in 2^32.
--- P-256 signing is deterministic too (RFC 6979): a secret and a message
--- always give the same signature.

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local raw = require("cosmic.internal.sign")

local record Sign
end

--- The 32-byte public key of the 32-byte `seed`. Raises on a seed of
--- another length.
---
---     local public = Sign.ed25519_public(seed)
function Sign.ed25519_public(seed: string): string
  return raw.ed25519_public(seed)
end

--- The 64-byte signature of `message`, of any length, under the 32-byte
--- `seed`. Raises on a seed of another length.
---
---     local signature = Sign.ed25519(seed, "message")
function Sign.ed25519(seed: string, message: string): string
  return raw.ed25519(seed, message)
end

--- Whether `signature` is one of `message` under the key `public`. Every
--- argument may come from anyone: bytes that do not verify answer false
--- and nothing raises, a key that is not 32 bytes or a signature that is
--- not 64 included.
---
--- A signature is its halves R and S. It verifies when the key and R
--- each decode to a point of the curve, S is below the group order L,
--- and 8(S·B - h·A - R) is the neutral point, where A is the key, B the
--- base point and h the SHA-512 of R, the key and the message: the
--- equation RFC 8032 section 5.1.7 gives first. So:
---
--- - S of L or more is refused: adding L to a valid signature's S does
---   not make a second signature of the same message.
--- - A key or an R that is no point of the curve is refused.
--- - A point's encoding RFC 8032 refuses to decode is read as the point
---   it reduces to: a y of 2^255 - 19 or more, or an x of 0 with the
---   sign bit set.
--- - A key of small order is accepted. Under the neutral point as the
---   key, the signature whose R is the neutral point and whose S is 0
---   verifies for every message, so a signature proves who signed only
---   under a key the caller has reason to trust.
---
---     local ok = Sign.ed25519_verify(public, "message", signature)
function Sign.ed25519_verify(public: string, message: string, signature: string): boolean
  return raw.ed25519_verify(public, message, signature)
end

--- A new P-256 secret: a scalar from 1 to n - 1 as 32 big-endian
--- bytes, drawn from the system's entropy. It is the whole secret: keep
--- it as [`Sign.ed25519`]'s seed is kept. Raises when the entropy source
--- fails.
---
---     local secret = Sign.p256_secret()
function Sign.p256_secret(): string
  return raw.p256_secret()
end

--- The 65-byte public point of the P-256 `secret`, uncompressed as SEC 1
--- spells it: the byte 0x04, then X and Y as 32 big-endian bytes each.
--- Raises on a secret that is not 32 bytes, or that is 0 or n or more,
--- and when the system's entropy source fails: mbedtls blinds its work
--- on a secret with random values.
---
---     local public = Sign.p256_public(secret)
---     local x, y = public:sub(2, 33), public:sub(34, 65)
function Sign.p256_public(secret: string): string
  return raw.p256_public(secret)
end

--- The 64-byte ECDSA signature of the SHA-256 of `message`, of any
--- length, under the P-256 `secret`: R then S, as 32 big-endian bytes
--- each, the form JWS ES256 takes (RFC 7518 section 3.4). A DER
--- signature, as X.509 takes one, is the same two integers in an ASN.1
--- SEQUENCE. Signing is deterministic (RFC 6979). Raises as
--- [`Sign.p256_public`] does.
---
---     local signature = Sign.p256(secret, "message")
function Sign.p256(secret: string, message: string): string
  return raw.p256(secret, message)
end

--- Whether `signature`, R then S as [`Sign.p256`] makes it, is one of
--- the SHA-256 of `message` under the 65-byte uncompressed point
--- `public`. Every argument may come from anyone: a point that is not on
--- the curve, an R or S of 0 or n or more, and an argument of the wrong
--- size answer false, and nothing raises. Both S and n - S verify, as
--- ECDSA has it: a signature is not unique to its message, so do not
--- take one as an identifier of what was signed.
---
---     local ok = Sign.p256_verify(public, "message", signature)
function Sign.p256_verify(public: string, message: string, signature: string): boolean
  return raw.p256_verify(public, message, signature)
end

return Sign
