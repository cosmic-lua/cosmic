--- Worked examples for [`cosmic.acme`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Acme = require("cosmic.acme")
local Codec = require("cosmic.codec")
local Sign = require("cosmic.sign")

local record Example
end

--- An account key: keep the secret, since the account is the key.
function Example.p256_key()
  local secret = Sign.p256_secret()
  local key = Acme.p256_key(secret)
  print(key.alg, key.jwk["crv"])
  assert(key.alg == "ES256" and key.jwk["kty"] == "EC")
end

--- The thumbprint joins each challenge's token in its key authorization.
function Example.thumbprint()
  local key = Acme.p256_key(Sign.p256_secret())
  local thumbprint = Acme.thumbprint(key)
  print(thumbprint)
  assert(#thumbprint == 43 and Codec.unbase64url(thumbprint) ~= nil)
end

--- A certificate signing request for two names, as DER: a SEQUENCE.
function Example.csr()
  local key = Acme.p256_key(Sign.p256_secret())
  local csr = assert(Acme.csr(key, { "example.com", "www.example.com" }))
  print(#csr)
  assert(csr:byte(1) == 0x30)
end

--- A client for Let's Encrypt's staging server, which issues
--- untrusted certificates: try a flow there, then use
--- [`Acme.LETS_ENCRYPT`]. It sends nothing until a method needs it.
function Example.client()
  print("staging:", Acme.LETS_ENCRYPT_STAGING, "production:", Acme.LETS_ENCRYPT)
  local client = Acme.client({ directory = Acme.LETS_ENCRYPT_STAGING, key = Acme.p256_key(Sign.p256_secret()) })
  print(client.thumbprint)
  assert(#client.thumbprint == 43)
end

return Example
