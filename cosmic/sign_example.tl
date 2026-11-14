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

return Example
