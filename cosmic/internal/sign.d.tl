-- Ed25519 signatures (RFC 8032) at the Lua boundary, as the core
-- provides them through Monocypher, and ECDSA over P-256 (FIPS 186-5)
-- and RSA PKCS #1 v1.5 signatures (RFC 8017) as it provides them
-- through mbedtls.
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
  -- A new 32-byte P-256 secret scalar, drawn from the system's entropy.
  -- Raises when the entropy source fails.
  p256_secret: function(): string
  -- The 65-byte uncompressed public point (0x04, X, Y) of a 32-byte
  -- secret. Raises on a secret of another length or out of range, and
  -- when the entropy source mbedtls blinds with fails.
  p256_public: function(secret: string): string
  -- The 64-byte signature (R, S) of message's SHA-256 under a 32-byte
  -- secret, by deterministic ECDSA. Raises as p256_public does.
  p256: function(secret: string, message: string): string
  -- Whether signature is one of message under the 65-byte public point;
  -- false for any argument of the wrong size or shape.
  p256_verify: function(public: string, message: string, signature: string): boolean
  -- A new RSA key of `bits` (2048, 3072 or 4096; 2048 when nil) and
  -- e = 65537, as a DER RSAPrivateKey. Raises on other bits, and when the
  -- entropy source fails.
  rsa_secret: function(bits?: integer): string
  -- The DER RSAPublicKey of a DER RSAPrivateKey. Raises on bytes that
  -- are none, on a key of fewer than 2048 bits or more than 4096, and
  -- when the entropy source mbedtls blinds with fails.
  rsa_public: function(secret: string): string
  -- The PKCS #1 v1.5 signature of message's SHA-256 under a DER
  -- RSAPrivateKey, as long as the modulus. Raises as rsa_public does.
  rsa: function(secret: string, message: string): string
  -- Whether signature is one of message under the DER RSAPublicKey;
  -- false for any argument of the wrong size or shape, and for a key of
  -- fewer than 2048 bits or more than 4096.
  rsa_verify: function(public: string, message: string, signature: string): boolean
end

return sign
