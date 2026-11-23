--- Worked examples for [`cosmic.key`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Key = require("cosmic.key")
local Rand = require("cosmic.rand")

local record Example
end

--- A new key of each algorithm signs, and its public key checks the
--- signature. An RSA key's JWK is the modulus `n` and the exponent `e`.
function Example.generate()
  local algs: {Key.Alg} = { "ed25519", "p256", "rsa" }
  for _, alg in ipairs(algs) do
    local key = Key.generate(alg)
    local signature = key:sign("message")
    print(tostring(key), #signature, key.public:jwk()["kty"])
    assert(key.public:verify("message", signature))
  end
end

--- A key saved as PEM and read back: the same key, so the same
--- thumbprint.
function Example.read()
  local key = Key.generate("p256")
  local pem = key:pem()
  local read = assert(Key.read(pem))
  print(pem:match("^[^\n]+"))
  assert(read.public:thumbprint() == key.public:thumbprint())
end

--- A key of a seed kept as bytes: the seed is the whole secret.
function Example.secret()
  local key = assert(Key.secret("ed25519", (assert(Rand.entropy(32)))))
  print(key.alg, #key.public.bytes)
  assert(#key.public.bytes == 32)
end

--- A public key of bytes a peer sent, which checks what the peer signs.
function Example.public()
  local peer = Key.generate("ed25519")
  local public = assert(Key.public("ed25519", peer.public.bytes))
  print(public:thumbprint())
  assert(public:verify("hello", peer:sign("hello")))
end

return Example
