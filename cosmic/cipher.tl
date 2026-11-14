--- Authenticated encryption under a shared key, and X25519 key agreement,
--- which gives two parties such a key over a channel anyone can read.
---
--- - [`Cipher.seal`] encrypts a message and appends a tag;
---   [`Cipher.open`] answers the message only when the tag proves that
---   the holder of the key sealed exactly these bytes.
--- - [`Cipher.x25519_public`] is the public key of a private key, and
---   [`Cipher.x25519`] the secret that one party's private key and the
---   other's public key share.
---
---     local key = assert(Rand.entropy(Cipher.key_length))
---     local nonce = assert(Rand.entropy(Cipher.nonce_length))
---     local sealed = Cipher.seal("chacha20-poly1305", key, nonce, "attack at dawn")
---     assert(Cipher.open("chacha20-poly1305", key, nonce, sealed) == "attack at dawn")
---
--- Keys, nonces and what these functions answer are raw bytes. A key is
--- [`Cipher.key_length`] bytes that nobody can guess: `Rand.entropy(32)`
--- of [`cosmic.rand`], or a key derivation's output, never a password.

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why it is off
-- the public surface.
local raw = require("cosmic.internal.cipher")

local record Cipher
  --- The algorithms, by exactly these lower-case names. `chacha20-poly1305`
  --- is ChaCha20-Poly1305 as RFC 8439 defines it. A name that is not one
  --- of these raises.
  enum Algorithm
    "chacha20-poly1305"
  end

  --- How many bytes a key is, 32: [`Cipher.seal`]'s, and an X25519
  --- private key, public key and shared secret alike.
  key_length: integer
  --- How many bytes a nonce is, 12.
  nonce_length: integer
  --- How many bytes [`Cipher.seal`] adds to a message, 16: the tag.
  tag_length: integer
end

Cipher.key_length = 32
Cipher.nonce_length = 12
Cipher.tag_length = 16

--- `plaintext` encrypted under `key` and `nonce`: the ciphertext, as
--- long as the plaintext, followed by the tag, [`Cipher.tag_length`]
--- bytes that authenticate the ciphertext and `aad` together. `aad` is
--- data sent in the clear that the message is bound to (a header, a
--- sequence number): it is not in what `seal` answers, and
--- [`Cipher.open`] needs the same bytes. Absent, it is empty.
---
--- A nonce is used once per key. Sealing two messages under the same
--- key and nonce shows the difference of their plaintexts and lets an
--- attacker forge messages under that key. The nonce is no secret: send
--- it beside the message. A counter that never repeats serves, and so
--- does `Rand.entropy(12)` for up to some billions of messages under
--- one key.
---
--- Raises when `key` is not [`Cipher.key_length`] bytes or `nonce` not
--- [`Cipher.nonce_length`].
function Cipher.seal(algorithm: Cipher.Algorithm, key: string, nonce: string, plaintext: string,
                     aad?: string): string
  return raw.seal(algorithm, key, nonce, plaintext, aad)
end

--- The plaintext of `sealed`, which [`Cipher.seal`] answered for the
--- same algorithm, key, nonce and `aad`, and "". nil and why when
--- `sealed` is shorter than a tag or its tag does not authenticate it:
--- a bit of the ciphertext, the tag, the `aad`, the nonce or the key
--- differs. Nothing of the message is released then. Raises as `seal`
--- does.
function Cipher.open(algorithm: Cipher.Algorithm, key: string, nonce: string, sealed: string,
                     aad?: string): string?, string
  return raw.open(algorithm, key, nonce, sealed, aad)
end

--- The X25519 public key (RFC 7748) of a private key, 32 bytes each:
--- what a party sends the other. A private key is 32 bytes nobody can
--- guess, `Rand.entropy(32)` of [`cosmic.rand`]; it is clamped as the
--- RFC says, so any 32 bytes are one. Raises on another length.
function Cipher.x25519_public(private: string): string
  return raw.x25519_public(private)
end

--- The 32-byte secret that `private` and the peer's public key share,
--- and "": the peer computes the same bytes from its private key and
--- this party's public key, and nobody who saw only the public keys
--- can. nil and why when `peer_public` is a point of low order, which
--- makes the secret all zero bytes whatever the private key: a peer
--- that sends one is choosing the secret, not agreeing on it. Raises
--- when either key is not 32 bytes.
---
--- The secret is not a key yet. Pass it through a key derivation
--- ([`Hash.hkdf`]), together with both public keys, and use what that
--- answers as [`Cipher.seal`]'s key. Public keys are not authenticated here: a
--- party that must know who the peer is checks the peer's public key
--- against one it already trusts.
function Cipher.x25519(private: string, peer_public: string): string?, string
  return raw.x25519(private, peer_public)
end

return Cipher
