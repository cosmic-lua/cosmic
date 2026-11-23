--- Worked examples for [`cosmic.key`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Cipher = require("cosmic.cipher")
local Hash = require("cosmic.hash")
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

--- Two parties agreeing on a key over a channel anyone can read. Each
--- makes an X25519 key, sends its public key, and computes the same
--- secret from its own private key and the other's public key. Both
--- derive the message key from the secret and the two public keys with
--- [`Hash.hkdf`], and one seals what the other opens.
function Example.agree()
  local alice = Key.generate("x25519")
  local bob = Key.generate("x25519")
  local alice_public = alice.public.bytes
  local bob_public = bob.public.bytes

  local alice_secret = assert(alice:agree(bob.public))
  local bob_secret = assert(bob:agree(alice.public))
  assert(Hash.equal(alice_secret, bob_secret))

  local context = "example message key" .. alice_public .. bob_public
  local alice_key = Hash.hkdf("sha256", alice_secret, "", context, Cipher.key_length)
  local bob_key = Hash.hkdf("sha256", bob_secret, "", context, Cipher.key_length)
  local nonce = assert(Rand.entropy(Cipher.nonce_length))
  local sealed = Cipher.seal("chacha20-poly1305", alice_key, nonce, "hello, bob")
  local message = assert(Cipher.open("chacha20-poly1305", bob_key, nonce, sealed))
  print(message)
  assert(message == "hello, bob")
end

return Example
