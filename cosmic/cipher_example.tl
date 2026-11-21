--- Worked examples for [`cosmic.cipher`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Cipher = require("cosmic.cipher")
local Hash = require("cosmic.hash")
local Rand = require("cosmic.rand")

local record Example end

--- Sealing a message under a fresh key and nonce, and opening it. The
--- header travels in the clear beside the sealed message, and the
--- message opens only with the header it was sealed with.
function Example.seal()
  local key = assert(Rand.entropy(Cipher.key_length))
  local nonce = assert(Rand.entropy(Cipher.nonce_length))
  local header = "to: bob"
  local sealed = Cipher.seal("chacha20-poly1305", key, nonce, "attack at dawn", header)
  print(#sealed)
  assert(#sealed == #"attack at dawn" + Cipher.tag_length)
  local message = assert(Cipher.open("chacha20-poly1305", key, nonce, sealed, header))
  print(message)
  assert(message == "attack at dawn")
end

--- A sealed message that was changed on the way, or is opened with
--- another header, answers nil and why, and none of its plaintext.
function Example.open()
  local key = assert(Rand.entropy(Cipher.key_length))
  local nonce = assert(Rand.entropy(Cipher.nonce_length))
  local sealed = Cipher.seal("chacha20-poly1305", key, nonce, "pay bob 10", "invoice 7")
  local tampered = sealed:sub(1, 8) .. string.char(assert(sealed:byte(9)) ~ 1) .. sealed:sub(10)
  local message, why = Cipher.open("chacha20-poly1305", key, nonce, tampered, "invoice 7")
  print(message, why)
  assert(message == nil and why ~= "")
  assert(Cipher.open("chacha20-poly1305", key, nonce, sealed, "invoice 8") == nil)
  assert(Cipher.open("chacha20-poly1305", key, nonce, sealed, "invoice 7") == "pay bob 10")
end

--- Two parties agreeing on a key over a channel anyone can read. Each
--- makes a private key, sends its public key, and computes the same
--- secret from its own private key and the other's public key. Both
--- derive the message key from the secret and the two public keys with
--- [`Hash.hkdf`], and one seals what the other opens.
function Example.x25519()
  local alice = assert(Rand.entropy(32))
  local bob = assert(Rand.entropy(32))
  local alice_public = Cipher.x25519_public(alice)
  local bob_public = Cipher.x25519_public(bob)

  local alice_secret = assert(Cipher.x25519(alice, bob_public))
  local bob_secret = assert(Cipher.x25519(bob, alice_public))
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

--- A session's two ends, each sealing under its own key, both derived
--- from one shared secret. Neither end handles a nonce. A message opens
--- once, in its turn, and one that fails does not disturb the next.
function Example.channel()
  local secret = assert(Rand.entropy(32))
  local to_server = Hash.hkdf("sha256", secret, "", "client to server", Cipher.key_length)
  local to_client = Hash.hkdf("sha256", secret, "", "server to client", Cipher.key_length)
  local client = Cipher.channel(to_server, to_client)
  local server = Cipher.channel(to_client, to_server)

  local request = client:seal("GET /status", "frame 1")
  print(assert(server:open(request, "frame 1")))
  print(assert(client:open(server:seal("200 ok"))))

  local replayed, why = server:open(request, "frame 1")
  print(replayed, why ~= "")
  local second = client:seal("GET /status", "frame 2")
  assert(second ~= request)
  print(assert(server:open(second, "frame 2")))
end

return Example
