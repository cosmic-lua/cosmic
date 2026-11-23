--- Worked examples for [`cosmic.acme`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Acme = require("cosmic.acme")
local Key = require("cosmic.key")

local record Example
end

--- A certificate signing request for two names, as DER: a SEQUENCE.
function Example.csr()
  local key = Key.generate("p256")
  local csr = assert(Acme.csr(key, { "example.com", "www.example.com" }))
  print(#csr)
  assert(csr:byte(1) == 0x30)
end

--- A client for Let's Encrypt's staging server, which issues
--- untrusted certificates: try a flow there, then use
--- [`Acme.LETS_ENCRYPT`]. It sends nothing until a method needs it.
function Example.client()
  print("staging:", Acme.LETS_ENCRYPT_STAGING, "production:", Acme.LETS_ENCRYPT)
  local client = Acme.client({ directory = Acme.LETS_ENCRYPT_STAGING, key = Key.generate("p256") })
  print(client.thumbprint)
  assert(#client.thumbprint == 43)
end

return Example
