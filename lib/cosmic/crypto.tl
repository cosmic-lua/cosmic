--- Symmetric encryption utilities.
--- Provides authenticated encryption using SHA-256-based CTR mode with HMAC-SHA256.
--- For password-based encryption, Argon2 key derivation is used.
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---
---   -- Key-based encryption (key should be 32 bytes)
---   local key = require("cosmic.rand").bytes(32)
---   local ciphertext, err = crypto.encrypt("hello", key)
---   local plaintext, err = crypto.decrypt(ciphertext, key)
---
---   -- Password-based encryption
---   local ciphertext, err = crypto.encrypt_with_password("hello", "my password")
---   local plaintext, err = crypto.decrypt_with_password(ciphertext, "my password")
---
--- Wire format for encrypt():
---   nonce(16) || mac(32) || ciphertext_bytes
---
--- Wire format for encrypt_with_password():
---   salt(32) || nonce(16) || mac(32) || ciphertext_bytes
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- XOR two byte strings together.
-- Truncates to the shorter of the two lengths.
local function xor_bytes(a: string, b: string): string
  local len = math.min(#a, #b)
  local result: {string} = {}
  for i = 1, len do
    local ba = a:byte(i)
    local bb = b:byte(i)
    result[i] = string.char(ba ~ bb)
  end
  return table.concat(result)
end

-- Pad or truncate a key to exactly block_size bytes using SHA-256.
local function normalize_key(key: string, block_size: number): string
  if #key > block_size then
    key = cosmo.Sha256(key)
  end
  if #key < block_size then
    key = key .. string.rep("\0", (block_size - #key) as integer)
  end
  return key
end

-- Compute HMAC-SHA256(key, msg).
-- RFC 2104: HMAC(k, m) = SHA256((k XOR opad) || SHA256((k XOR ipad) || m))
local function hmac_sha256(key: string, msg: string): string
  local block_size = 64
  local norm_key = normalize_key(key, block_size)
  local ipad = string.rep("\x36", block_size)
  local opad = string.rep("\x5c", block_size)
  local inner = cosmo.Sha256(xor_bytes(norm_key, ipad) .. msg)
  return cosmo.Sha256(xor_bytes(norm_key, opad) .. inner)
end

-- Generate a keystream of `length` bytes using SHA-256 counter mode.
-- Each 32-byte block is SHA256(key || nonce || counter_byte).
local function ctr_keystream(key: string, nonce: string, length: number): string
  local blocks: {string} = {}
  local num_blocks = math.ceil(length / 32)
  for i = 0, num_blocks - 1 do
    blocks[i + 1] = cosmo.Sha256(key .. nonce .. string.char(i % 256) .. string.char(math.floor(i / 256) % 256))
  end
  local stream = table.concat(blocks)
  return stream:sub(1, length as integer)
end

-- Compare two strings in constant time to prevent timing attacks.
-- Returns true iff a == b.
local function ct_equal(a: string, b: string): boolean
  if #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = diff | (a:byte(i) ~ b:byte(i))
  end
  return diff == 0
end

-- Derive encryption and MAC subkeys from a master key.
local function derive_keys(key: string): string, string
  local enc_key = cosmo.Sha256(key .. "cosmic-enc-v1:enc")
  local mac_key = cosmo.Sha256(key .. "cosmic-enc-v1:mac")
  return enc_key, mac_key
end

--- Encrypt plaintext with a key using authenticated encryption.
--- The key should be 32 bytes of high-entropy data (e.g. from cosmic.rand).
--- Returns a self-contained ciphertext blob that includes the nonce and MAC.
--- @param plaintext string The data to encrypt
--- @param key string The encryption key (any length; 32 bytes recommended)
--- @return string? The ciphertext blob, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if type(plaintext) ~= "string" then
    return nil, "plaintext must be a string"
  end
  if type(key) ~= "string" or #key == 0 then
    return nil, "key must be a non-empty string"
  end

  local enc_key, mac_key = derive_keys(key)
  local nonce = rand.bytes(16)
  local keystream = ctr_keystream(enc_key, nonce, #plaintext)
  local ciphertext_bytes = xor_bytes(plaintext, keystream)
  local mac = hmac_sha256(mac_key, nonce .. ciphertext_bytes)
  return nonce .. mac .. ciphertext_bytes
end

--- Decrypt a ciphertext blob produced by encrypt().
--- Returns nil + error if authentication fails or the blob is malformed.
--- @param ciphertext string The ciphertext blob (from encrypt())
--- @param key string The encryption key (must match the one used to encrypt)
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt(ciphertext: string, key: string): string, string
  if type(ciphertext) ~= "string" then
    return nil, "ciphertext must be a string"
  end
  if type(key) ~= "string" or #key == 0 then
    return nil, "key must be a non-empty string"
  end

  -- Minimum: 16 (nonce) + 32 (mac) = 48 bytes
  if #ciphertext < 48 then
    return nil, "ciphertext too short"
  end

  local nonce = ciphertext:sub(1, 16)
  local mac = ciphertext:sub(17, 48)
  local ciphertext_bytes = ciphertext:sub(49)

  local enc_key, mac_key = derive_keys(key)
  local expected_mac = hmac_sha256(mac_key, nonce .. ciphertext_bytes)

  if not ct_equal(mac, expected_mac) then
    return nil, "authentication failed"
  end

  local keystream = ctr_keystream(enc_key, nonce, #ciphertext_bytes)
  return xor_bytes(ciphertext_bytes, keystream)
end

-- Argon2 parameters for key derivation.
-- Low cost for tests; these defaults are reasonable for interactive use.
local KDF_M_COST = 4096
local KDF_T_COST = 3
local KDF_PARALLELISM = 1
local KDF_HASH_LEN = 32

-- Derive a 32-byte key from a password and salt using Argon2id.
local function derive_key_from_password(password: string, salt: string): string, string
  -- hash_encoded returns a PHC-encoded string; we need raw key bytes.
  -- We use it with a fixed hash_len and extract the key via a known approach:
  -- derive the PHC string, then take SHA256 of it for a 32-byte key.
  -- This is safe because the PHC string is uniquely determined by (password, salt, params).
  local encoded, err = argon2.hash_encoded(password, salt, {
      m_cost = KDF_M_COST,
      t_cost = KDF_T_COST,
      parallelism = KDF_PARALLELISM,
      hash_len = KDF_HASH_LEN,
    }) as(string, any)
  if not encoded then
    return nil, "key derivation failed: " .. tostring(err or "unknown error")
  end
  -- Derive a 32-byte key from the PHC string.
  local derived_key = cosmo.Sha256(encoded .. "cosmic-kdf-v1")
  return derived_key
end

--- Encrypt plaintext using a password.
--- Derives a key from the password using Argon2id and a random salt.
--- The salt is embedded in the returned ciphertext blob.
--- @param plaintext string The data to encrypt
--- @param password string The password to derive the key from
--- @return string? The ciphertext blob (salt + encrypted data), or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  if type(plaintext) ~= "string" then
    return nil, "plaintext must be a string"
  end
  if type(password) ~= "string" or #password == 0 then
    return nil, "password must be a non-empty string"
  end

  local salt = rand.bytes(32)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end

  local ciphertext, err2 = encrypt(plaintext, key)
  if not ciphertext then
    return nil, err2
  end

  return salt .. ciphertext
end

--- Decrypt a ciphertext blob produced by encrypt_with_password().
--- Returns nil + error if the password is wrong or the blob is malformed.
--- @param ciphertext string The ciphertext blob (from encrypt_with_password())
--- @param password string The password used to encrypt
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt_with_password(ciphertext: string, password: string): string, string
  if type(ciphertext) ~= "string" then
    return nil, "ciphertext must be a string"
  end
  if type(password) ~= "string" or #password == 0 then
    return nil, "password must be a non-empty string"
  end

  -- Minimum: 32 (salt) + 48 (nonce + mac) = 80 bytes
  if #ciphertext < 80 then
    return nil, "ciphertext too short"
  end

  local salt = ciphertext:sub(1, 32)
  local inner = ciphertext:sub(33)

  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end

  return decrypt(inner, key)
end

local record CryptoModule
  encrypt: function(plaintext: string, key: string): string, string
  decrypt: function(ciphertext: string, key: string): string, string
  encrypt_with_password: function(plaintext: string, password: string): string, string
  decrypt_with_password: function(ciphertext: string, password: string): string, string
end

local M: CryptoModule = {
  encrypt = encrypt,
  decrypt = decrypt,
  encrypt_with_password = encrypt_with_password,
  decrypt_with_password = decrypt_with_password,
}

return M
