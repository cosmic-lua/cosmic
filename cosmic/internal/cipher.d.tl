-- Authenticated encryption and X25519 key agreement at the Lua boundary,
-- as the core provides them. Every fallible function answers `value, ""`
-- on success and `nil, error` on failure.
--- @kind binding

local record cipher
  -- `plaintext` encrypted and authenticated, with `aad`, under `key` and
  -- `nonce`: the ciphertext, as long as the plaintext, then the 16-byte
  -- tag. The one algorithm is chacha20-poly1305, of a 32-byte key and a
  -- 12-byte nonce. Raises when no algorithm has that name, or the key or
  -- nonce is not the algorithm's length.
  seal: function(algorithm: string, key: string, nonce: string, plaintext: string, aad?: string): string
  -- The plaintext of what `seal` answered for the same algorithm, key,
  -- nonce and aad; nil, error when `sealed` is shorter than a tag or does
  -- not authenticate. Raises as `seal` does.
  open: function(algorithm: string, key: string, nonce: string, sealed: string, aad?: string): string?, string
  -- The 32-byte public key of a 32-byte private key, which is clamped as
  -- RFC 7748 says. Raises on a private key of another length.
  x25519_public: function(private: string): string
  -- The 32-byte secret a private key and a peer's public key share; nil,
  -- error when the peer's key is a point of low order, whose secret is
  -- all zero bytes. Raises when either is not 32 bytes.
  x25519: function(private: string, peer_public: string): string?, string
end

return cipher
