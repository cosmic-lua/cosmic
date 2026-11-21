-- Ed25519 signatures (RFC 8032) at the Lua boundary, as the core
-- provides them through Monocypher.
--- @kind binding

local record sign
  -- The 32-byte public key of a 32-byte seed. Raises on a seed of
  -- another length.
  ed25519_public: function(seed: string): string
  -- The 64-byte signature of message under a 32-byte seed. Raises on a
  -- seed of another length.
  ed25519: function(seed: string, message: string): string
  -- Whether signature is one of message under the public key; false for
  -- a key that is not 32 bytes or a signature that is not 64.
  ed25519_verify: function(public: string, message: string, signature: string): boolean
end

return sign
