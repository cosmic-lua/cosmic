--- Symmetric authenticated encryption.
--- Provides AES-GCM-like authenticated encryption using SHA-256 primitives.
---
--- The construction:
---   - Stream cipher: SHA-256 counter mode (keystream XOR plaintext)
---   - Authentication: HMAC-SHA256
---   - Key derivation: SHA-256("enc"|key) and SHA-256("mac"|key)
---   - Output format: nonce(16) || tag(32) || ciphertext
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local key = require("cosmic.rand").bytes(32)
---   local ct, err = crypto.encrypt("secret", key)
---   local pt, err = crypto.decrypt(ct, key)
---
---   -- Password-based (derives key via Argon2):
---   local ct, err = crypto.encrypt_with_password("secret", "my password")
---   local pt, err = crypto.decrypt_with_password(ct, "my password")
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

local NONCE_LEN < const > = 16
local TAG_LEN < const > = 32
local KEY_LEN < const > = 32
local BLOCK_LEN < const > = 32

-- XOR two equal-length byte strings.
-- Returns a string of the same length.
local function xor_bytes(a: string, b: string): string
  local n = #a
  local out: {string} = {}
  for i = 1, n do
    local ba = string.byte(a, i)
    local bb = string.byte(b, i)
    out[i] = string.char((ba ~ bb) as integer)
  end
  return table.concat(out)
end

-- HMAC-SHA256 using the standard two-pass construction.
-- key and data are raw byte strings. key must be <= 64 bytes.
local function hmac_sha256(key: string, data: string): string
  -- Pad key to 64 bytes (SHA-256 block size)
  local k = key
  if #k > 64 then
    k = cosmo.Sha256(k)
  end
  while #k < 64 do
    k = k .. "\0"
  end

  local ipad: {string} = {}
  local opad: {string} = {}
  for i = 1, 64 do
    local b = string.byte(k, i)
    ipad[i] = string.char((b ~ 0x36) as integer)
    opad[i] = string.char((b ~ 0x5c) as integer)
  end
  local inner = cosmo.Sha256(table.concat(ipad) .. data)
  return cosmo.Sha256(table.concat(opad) .. inner)
end

-- Generate `length` bytes of keystream from key and nonce using SHA-256 counter mode.
-- keystream_i = SHA-256(key || nonce || uint32_be(i))
local function keystream(key: string, nonce: string, length: integer): string
  local blocks: {string} = {}
  local i = 0
  local generated = 0
  while generated < length do
    -- Encode counter as 4-byte big-endian
    local b4 = string.char(
      ((i >> 24) & 0xff) as integer,
      ((i >> 16) & 0xff) as integer,
      ((i >> 8) & 0xff) as integer,
      (i & 0xff) as integer
    )
    local block = cosmo.Sha256(key .. nonce .. b4)
    local need = length - generated
    if need < BLOCK_LEN then
      blocks[#blocks + 1] = block:sub(1, need)
      generated = length
    else
      blocks[#blocks + 1] = block
      generated = generated + BLOCK_LEN
    end
    i = i + 1
  end
  return table.concat(blocks)
end

--- Encrypt plaintext with a 32-byte key.
--- Returns an authenticated ciphertext blob: nonce(16) || tag(32) || ciphertext.
--- @param plaintext string The data to encrypt
--- @param key string A 32-byte encryption key
--- @return string? The ciphertext blob, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end

  -- Derive subkeys
  local enc_key = cosmo.Sha256("enc" .. key)
  local mac_key = cosmo.Sha256("mac" .. key)

  -- Generate nonce
  local nonce = rand.bytes(NONCE_LEN)

  -- Encrypt
  local ks = keystream(enc_key, nonce, #plaintext)
  local ciphertext = xor_bytes(plaintext, ks)

  -- Authenticate: tag = HMAC-SHA256(mac_key, nonce || ciphertext)
  local tag = hmac_sha256(mac_key, nonce .. ciphertext)

  return nonce .. tag .. ciphertext, nil
end

--- Decrypt a ciphertext blob with a 32-byte key.
--- Verifies the authentication tag before decrypting.
--- @param blob string The ciphertext blob (from encrypt)
--- @param key string A 32-byte encryption key
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt(blob: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  local min_len = NONCE_LEN + TAG_LEN
  if #blob < min_len then
    return nil, "ciphertext too short"
  end

  -- Parse blob
  local nonce = blob:sub(1, NONCE_LEN)
  local tag = blob:sub(NONCE_LEN + 1, NONCE_LEN + TAG_LEN)
  local ciphertext = blob:sub(NONCE_LEN + TAG_LEN + 1)

  -- Derive subkeys
  local enc_key = cosmo.Sha256("enc" .. key)
  local mac_key = cosmo.Sha256("mac" .. key)

  -- Verify tag (constant-time: accumulate XOR diff)
  local expected_tag = hmac_sha256(mac_key, nonce .. ciphertext)
  local diff = 0
  for i = 1, TAG_LEN do
    diff = diff | (string.byte(tag, i) ~ string.byte(expected_tag, i))
  end
  if diff ~= 0 then
    return nil, "authentication failed"
  end

  -- Decrypt
  local ks = keystream(enc_key, nonce, #ciphertext)
  if #ciphertext == 0 then
    return "", nil
  end
  return xor_bytes(ciphertext, ks), nil
end

-- Derive a 32-byte key from a password and salt using Argon2.
local function derive_key(password: string, salt: string): string, string
  local config: argon2.Config = {
    m_cost = 4096,
    t_cost = 3,
    parallelism = 1,
    hash_len = 32,
    variant = argon2.variants.argon2_id,
  }
  local encoded, err = argon2.hash_encoded(password, salt, config) as(string, any)
  if not encoded then
    return nil, tostring(err or "argon2 key derivation failed")
  end
  -- Extract the raw hash bytes from the encoded Argon2 string.
  -- Argon2 encoded format: $argon2id$v=19$m=...,t=...,p=...$<base64salt>$<base64hash>
  -- The last field is the base64-encoded hash.
  local b64hash = encoded:match("%$([^%$]+)$")
  if not b64hash then
    return nil, "failed to extract hash from argon2 output"
  end
  -- Argon2 uses unpadded base64; add padding if needed
  local pad = (4 - #b64hash % 4) % 4
  local padded = b64hash .. string.rep("=", pad)
  -- Replace URL-safe chars (argon2 uses standard base64 without +/)
  -- Actually argon2 uses its own base64 variant; cosmo.DecodeBase64 handles standard
  -- Argon2 uses standard alphabet but without padding, so this should work directly.
  local raw = cosmo.DecodeBase64(padded)
  if not raw or #raw < KEY_LEN then
    return nil, "argon2 hash too short for key"
  end
  return raw:sub(1, KEY_LEN), nil
end

--- Encrypt plaintext using a password (Argon2 key derivation).
--- Returns a blob: salt(16) || nonce(16) || tag(32) || ciphertext.
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @return string? The ciphertext blob, or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  local salt = rand.bytes(NONCE_LEN)
  local key, err = derive_key(password, salt)
  if not key then
    return nil, err
  end
  local ct, err2 = encrypt(plaintext, key)
  if not ct then
    return nil, err2
  end
  return salt .. ct, nil
end

--- Decrypt a blob encrypted with encrypt_with_password.
--- Re-derives the key from the embedded salt and password.
--- @param blob string The ciphertext blob (from encrypt_with_password)
--- @param password string The password used for encryption
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt_with_password(blob: string, password: string): string, string
  local min_len = NONCE_LEN + NONCE_LEN + TAG_LEN
  if #blob < min_len then
    return nil, "ciphertext too short"
  end
  local salt = blob:sub(1, NONCE_LEN)
  local rest = blob:sub(NONCE_LEN + 1)
  local key, err = derive_key(password, salt)
  if not key then
    return nil, err
  end
  return decrypt(rest, key)
end

local record CryptoModule
  encrypt: function(plaintext: string, key: string): string, string
  decrypt: function(blob: string, key: string): string, string
  encrypt_with_password: function(plaintext: string, password: string): string, string
  decrypt_with_password: function(blob: string, password: string): string, string
end

local M: CryptoModule = {
  encrypt = encrypt,
  decrypt = decrypt,
  encrypt_with_password = encrypt_with_password,
  decrypt_with_password = decrypt_with_password,
}

return M
