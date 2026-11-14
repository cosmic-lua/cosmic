--- Ed25519 signatures (RFC 8032), over raw bytes: a holder of a secret
--- seed signs a message, and anyone with the public key checks the
--- signature. [`Codec.hex`] and [`Codec.base64`] spell a key or a
--- signature for a person or a format.
---
--- - [`Sign.ed25519_public`] is the public key of a seed.
--- - [`Sign.ed25519`] signs a message under a seed.
--- - [`Sign.ed25519_verify`] checks a signature, and is safe to give
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

return Sign
