--- Symmetric encryption utilities.
--- Provides authenticated encryption using HMAC-SHA256 in CTR mode
--- with Encrypt-then-MAC construction.
---
--- Example usage (raw key):
---   local crypto = require("cosmic.crypto")
---   local key = require("cosmic.rand").bytes(32)
---   local ciphertext, err = crypto.encrypt("hello", key)
---   local plaintext, err = crypto.decrypt(ciphertext, key)
---
--- Example usage (password-based):
---   local crypto = require("cosmic.crypto")
---   local ciphertext, err = crypto.encrypt_with_password("hello", "secret")
---   local plaintext, err = crypto.decrypt_with_password(ciphertext, "secret")
---
--- Ciphertext format for encrypt: [nonce:16][tag:32][ciphertext:N]
--- Ciphertext format for encrypt_with_password: [salt:16][nonce:16][tag:32][ciphertext:N]
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- Encode a 32-bit unsigned integer as 4 big-endian bytes.
local function uint32_be(n: integer): string
  return string.char(
    (n >> 24) & 0xff as integer,
    (n >> 16) & 0xff as integer,
    (n >> 8) & 0xff as integer,
    n & 0xff as integer
  )
end

-- XOR two equal-length strings byte by byte.
-- Returns the XOR result and a boolean: true if all bytes were zero (equal).
local function xor_strings(a: string, b: string): string, boolean
  local len = #a
  local out: {integer} = {}
  local all_zero = true
  for i = 1, len do
    local xa = string.byte(a, i) as integer
    local xb = string.byte(b, i) as integer
    local xc = xa ~ xb
    if xc ~= 0 then
      all_zero = false
    end
    out[i] = xc
  end
  return string.char(table.unpack(out)), all_zero
end

-- CTR-mode encryption/decryption using HMAC-SHA256 blocks.
-- key: 32-byte encryption key
-- nonce: 16-byte nonce
-- data: plaintext or ciphertext
-- Returns the encrypted/decrypted bytes.
local function ctr_crypt(key: string, nonce: string, data: string): string
  local result: {string} = {}
  local pos = 1
  local counter = 0
  while pos <= #data do
    -- Generate a 32-byte keystream block
    local block = cosmo.GetCryptoHash("sha256", nonce .. uint32_be(counter), key)
    local remaining = #data - pos + 1
    local chunk_len = remaining < 32 and remaining or 32
    local chunk = data:sub(pos, pos + chunk_len - 1)
    local keystream = block:sub(1, chunk_len)
    local out, _ = xor_strings(chunk, keystream)
    result[#result + 1] = out
    pos = pos + chunk_len
    counter = counter + 1
  end
  return table.concat(result)
end

-- Derive a 32-byte key from a password and salt using Argon2id.
-- Returns raw key bytes or nil + error message.
local function argon2_derive_key(password: string, salt: string): string, string
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
  -- Extract trailing base64 segment: $argon2id$...$<salt_b64>$<hash_b64>
  local hash_b64 = encoded:match("%$([^%$]+)$")
  if not hash_b64 then
    return nil, "failed to parse argon2 output"
  end
  -- Add padding if needed
  local pad = (4 - #hash_b64 % 4) % 4
  local padded = hash_b64 .. string.rep("=", pad)
  local raw = cosmo.DecodeBase64(padded)
  if not raw or #raw ~= 32 then
    return nil, "failed to decode derived key from argon2 output"
  end
  return raw, nil
end

--- Encrypt plaintext with a 32-byte raw key.
--- Uses CTR-HMAC-SHA256 with Encrypt-then-MAC construction.
--- The key must be exactly 32 bytes.
--- @param plaintext string The data to encrypt
--- @param key string A 32-byte encryption key
--- @return string? The ciphertext blob ([nonce:16][tag:32][ciphertext:N]), or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if #key ~= 32 then
    return nil, "key must be exactly 32 bytes, got " .. tostring(#key)
  end
  local nonce = rand.bytes(16)
  -- Derive per-message subkeys using HMAC-SHA256
  local enc_key = cosmo.GetCryptoHash("sha256", "cosmic-enc" .. nonce, key)
  local mac_key = cosmo.GetCryptoHash("sha256", "cosmic-mac" .. nonce, key)
  -- Encrypt
  local ciphertext = ctr_crypt(enc_key, nonce, plaintext)
  -- Authenticate (Encrypt-then-MAC)
  local tag = cosmo.GetCryptoHash("sha256", nonce .. ciphertext, mac_key)
  return nonce .. tag .. ciphertext, nil
end

--- Decrypt a ciphertext blob with a 32-byte raw key.
--- Verifies the MAC before decrypting. Returns an error if authentication fails.
--- @param blob string The ciphertext blob ([nonce:16][tag:32][ciphertext:N])
--- @param key string A 32-byte encryption key
--- @return string? The decrypted plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt(blob: string, key: string): string, string
  if #key ~= 32 then
    return nil, "key must be exactly 32 bytes, got " .. tostring(#key)
  end
  if #blob < 48 then
    return nil, "ciphertext too short: must be at least 48 bytes"
  end
  local nonce = blob:sub(1, 16)
  local tag = blob:sub(17, 48)
  local ciphertext = blob:sub(49)
  -- Derive per-message subkeys
  local enc_key = cosmo.GetCryptoHash("sha256", "cosmic-enc" .. nonce, key)
  local mac_key = cosmo.GetCryptoHash("sha256", "cosmic-mac" .. nonce, key)
  -- Verify MAC (constant-time XOR comparison)
  local expected_tag = cosmo.GetCryptoHash("sha256", nonce .. ciphertext, mac_key)
  local _, equal = xor_strings(tag, expected_tag)
  if not equal then
    return nil, "authentication failed: ciphertext has been tampered with"
  end
  -- Decrypt
  local plaintext = ctr_crypt(enc_key, nonce, ciphertext)
  return plaintext, nil
end

--- Encrypt plaintext using a password with Argon2id key derivation.
--- Generates a random salt and derives a 32-byte key via Argon2id.
--- The resulting blob includes the salt for use during decryption.
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @return string? The ciphertext blob ([salt:16][nonce:16][tag:32][ciphertext:N]), or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  local salt = rand.bytes(16)
  local key, err = argon2_derive_key(password, salt)
  if not key then
    return nil, err
  end
  local blob, eerr = encrypt(plaintext, key)
  if not blob then
    return nil, eerr
  end
  return salt .. blob, nil
end

--- Decrypt a ciphertext blob using a password with Argon2id key derivation.
--- Reads the salt from the blob and derives the key before decrypting.
--- @param blob string The ciphertext blob ([salt:16][nonce:16][tag:32][ciphertext:N])
--- @param password string The password for key derivation
--- @return string? The decrypted plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt_with_password(blob: string, password: string): string, string
  if #blob < 16 then
    return nil, "ciphertext too short: must be at least 16 bytes"
  end
  local salt = blob:sub(1, 16)
  local rest = blob:sub(17)
  local key, err = argon2_derive_key(password, salt)
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
