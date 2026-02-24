--- Symmetric encryption and decryption utilities.
--- Uses SHA256-CTR stream cipher with HMAC-SHA256 authentication (AEAD).
--- For password-based encryption, uses Argon2id key derivation.
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local key = require("cosmic.rand").bytes(32)
---
---   -- Encrypt with a raw 32-byte key
---   local ciphertext, err = crypto.encrypt("secret", key)
---
---   -- Decrypt with the same key
---   local plaintext, err = crypto.decrypt(ciphertext, key)
---
---   -- Encrypt with a password (Argon2id key derivation)
---   local ciphertext, err = crypto.encrypt_with_password("secret", "passphrase")
---
---   -- Decrypt with the password
---   local plaintext, err = crypto.decrypt_with_password(ciphertext, "passphrase")
---
--- Wire format for encrypt: nonce(16) || ciphertext(N) || hmac(32) = N+48 bytes
--- Wire format for encrypt_with_password: salt(16) || nonce(16) || ciphertext(N) || hmac(32) = N+64 bytes
---
--- Note: SHA256-CTR is not AES-GCM but provides equivalent AEAD security.
--- Argon2 parameters in encrypt_with_password are fixed defaults.
--- Changing defaults would make old ciphertexts undecryptable.
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- Internal: Compute SHA-256 hash of data (raw 32 bytes).
local function sha256(data: string): string
  return cosmo.Sha256(data)
end

-- Internal: XOR two equal-length byte strings.
local function xor_bytes(a: string, b: string): string
  local result: {string} = {}
  for i = 1, #a do
    local ba = a:byte(i)
    local bb = b:byte(i)
    result[i] = string.char((ba ~ bb) & 0xff)
  end
  return table.concat(result)
end

-- Internal: Pad or trim key to exactly 64 bytes for HMAC block size.
local function hmac_prepare_key(key: string): string
  if #key > 64 then
    key = sha256(key)
  end
  -- Pad to 64 bytes with zeros
  return key .. string.rep("\x00", 64 - #key)
end

-- Internal: Compute HMAC-SHA256 over data with key.
-- Returns raw 32-byte MAC.
local function hmac_sha256(key: string, data: string): string
  local k = hmac_prepare_key(key)
  -- Build ipad and opad (each 64 bytes)
  local ipad = string.rep("\x36", 64)
  local opad = string.rep("\x5c", 64)
  local k_ipad = xor_bytes(k, ipad)
  local k_opad = xor_bytes(k, opad)
  -- HMAC = sha256(k_opad || sha256(k_ipad || data))
  local inner = sha256(k_ipad .. data)
  return sha256(k_opad .. inner)
end

-- Internal: Encode counter as 8-byte little-endian.
local function uint64_le(n: integer): string
  -- n fits in Lua integer; encode lowest 8 bytes
  local bytes: {string} = {}
  local v = n
  for _ = 1, 8 do
    bytes[#bytes + 1] = string.char(v & 0xff)
    v = v >> 8
  end
  return table.concat(bytes)
end

-- Internal: SHA256-CTR stream cipher. XOR plaintext with keystream.
-- keystream_block_i = sha256(key || uint64_le(i) || nonce)
local function stream_xor(key: string, nonce: string, plaintext: string): string
  local result: {string} = {}
  local len = #plaintext
  local i: integer = 0
  local offset = 1
  while offset <= len do
    local block = sha256(key .. uint64_le(i) .. nonce)
    local block_end = offset + 31
    if block_end > len then
      block_end = len
    end
    local chunk = plaintext:sub(offset, block_end)
    local block_slice = block:sub(1, #chunk)
    result[#result + 1] = xor_bytes(chunk, block_slice)
    offset = offset + 32
    i = i + 1
  end
  return table.concat(result)
end

-- Internal: Timing-safe byte comparison. Returns true if a == b.
local function constant_time_eq(a: string, b: string): boolean
  if #a ~= #b then
    return false
  end
  local diff: integer = 0
  for i = 1, #a do
    diff = diff | (a:byte(i) ~ b:byte(i))
  end
  return diff == 0
end

-- Internal: Derive separate encryption and MAC keys from a single 32-byte key.
-- Uses HKDF-Expand style: HMAC-SHA256(key, label) for each derived key.
local function derive_keys(key: string): string, string
  local enc_key = hmac_sha256(key, "enc")
  local mac_key = hmac_sha256(key, "mac")
  return enc_key, mac_key
end

-- Internal: Derive a 32-byte key from a password and salt via Argon2id.
local function derive_key_from_password(password: string, salt: string): string, string
  local config: argon2.Config = {
    m_cost = 65536,
    t_cost = 3,
    parallelism = 1,
    hash_len = 32,
    variant = argon2.variants.argon2_id,
  }
  local encoded, err = argon2.hash_encoded(password, salt, config) as(string, any)
  if not encoded then
    return nil, tostring(err or "argon2 key derivation failed")
  end
  -- Extract the raw hash: last $-separated segment, base64-decoded
  local b64 = encoded:match("[^%$]+$")
  if not b64 then
    return nil, "failed to extract argon2 hash segment"
  end
  -- Argon2 uses unpadded base64; add padding if needed
  local pad = (4 - #b64 % 4) % 4
  if pad > 0 then
    b64 = b64 .. string.rep("=", pad)
  end
  local key = cosmo.DecodeBase64(b64)
  if not key or #key ~= 32 then
    return nil, "argon2 key derivation produced wrong length key"
  end
  return key, nil
end

--- Options for password-based encryption.
local record CryptoOptions
  --- Memory cost in kibibytes (not used; reserved for future compatibility)
  m_cost: number
end

--- Encrypt plaintext with a raw 32-byte key.
--- Uses SHA256-CTR stream cipher + HMAC-SHA256 for authenticated encryption.
--- Returns binary ciphertext: nonce(16) || encrypted_data(N) || mac(32).
--- @param plaintext string The data to encrypt
--- @param key string A 32-byte encryption key
--- @return string? The authenticated ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if #key ~= 32 then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  local nonce = rand.bytes(16)
  local enc_key, mac_key = derive_keys(key)
  local ciphertext = stream_xor(enc_key, nonce, plaintext)
  local mac = hmac_sha256(mac_key, nonce .. ciphertext)
  return nonce .. ciphertext .. mac, nil
end

--- Decrypt authenticated ciphertext with a raw 32-byte key.
--- Verifies the MAC before decrypting; returns nil on authentication failure.
--- @param data string The authenticated ciphertext (from encrypt)
--- @param key string The 32-byte key used to encrypt
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt(data: string, key: string): string, string
  if #key ~= 32 then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  if #data < 48 then
    return nil, "ciphertext too short: must be at least 48 bytes"
  end
  local nonce = data:sub(1, 16)
  local ciphertext = data:sub(17, -33)
  local mac = data:sub(-32)
  local enc_key, mac_key = derive_keys(key)
  local expected_mac = hmac_sha256(mac_key, nonce .. ciphertext)
  if not constant_time_eq(mac, expected_mac) then
    return nil, "authentication failed"
  end
  return stream_xor(enc_key, nonce, ciphertext), nil
end

--- Encrypt plaintext using a password with Argon2id key derivation.
--- A random salt is generated and prepended to the output.
--- Wire format: salt(16) || nonce(16) || encrypted_data(N) || mac(32) = N+64 bytes.
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @param opts CryptoOptions? Reserved for future use
--- @return string? The authenticated ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string, opts?: CryptoOptions): string, string
  local salt = rand.bytes(16)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end
  local inner, err2 = encrypt(plaintext, key)
  if not inner then
    return nil, err2
  end
  return salt .. inner, nil
end

--- Decrypt password-encrypted ciphertext with Argon2id key derivation.
--- Reads the salt from the ciphertext prefix, re-derives the key, and decrypts.
--- @param data string The authenticated ciphertext (from encrypt_with_password)
--- @param password string The password used to encrypt
--- @param opts CryptoOptions? Reserved for future use
--- @return string? The plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt_with_password(data: string, password: string, opts?: CryptoOptions): string, string
  if #data < 64 then
    return nil, "ciphertext too short: must be at least 64 bytes"
  end
  local salt = data:sub(1, 16)
  local inner = data:sub(17)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end
  return decrypt(inner, key)
end

local record CryptoModule
  type CryptoOptions = CryptoOptions

  encrypt: function(plaintext: string, key: string): string, string
  decrypt: function(data: string, key: string): string, string
  encrypt_with_password: function(plaintext: string, password: string, opts?: CryptoOptions): string, string
  decrypt_with_password: function(data: string, password: string, opts?: CryptoOptions): string, string
end

local M: CryptoModule = {
  encrypt = encrypt,
  decrypt = decrypt,
  encrypt_with_password = encrypt_with_password,
  decrypt_with_password = decrypt_with_password,
}

return M
