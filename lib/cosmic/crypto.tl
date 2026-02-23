--- Symmetric encryption utilities.
--- Provides authenticated symmetric encryption using HMAC-SHA256 and SHA256-CTR.
---
--- Algorithm:
---   - Key derivation: HKDF-Expand (RFC 5869) from the provided key
---   - Encryption: SHA256-CTR stream cipher (counter-mode keystream XORed with plaintext)
---   - Authentication: HMAC-SHA256 over nonce||ciphertext (Encrypt-then-MAC)
---
--- encrypt() output format: nonce(12) || ciphertext(#pt) || hmac(32)
--- encrypt_with_password() output format: salt(16) || encrypt_output
---
--- Argon2id parameters for password-based key derivation:
---   m_cost=65536 (64 MiB), t_cost=3, parallelism=1, hash_len=32
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local ct, err = crypto.encrypt("secret", key)
---   local pt, err = crypto.decrypt(ct, key)
---   local ct, err = crypto.encrypt_with_password("secret", "passphrase")
---   local pt, err = crypto.decrypt_with_password(ct, "passphrase")
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- Constants
local BLOCK_SIZE < const > = 64 -- SHA256 block size in bytes
local NONCE_LEN < const > = 12 -- nonce length in bytes
local HMAC_LEN < const > = 32 -- HMAC-SHA256 output length in bytes
local SALT_LEN < const > = 16 -- Argon2 salt length in bytes
local KEY_LEN < const > = 32 -- derived key length in bytes

--- XOR two equal-length byte strings.
--- @param a string
--- @param b string Must be same length as a
--- @return string
local function xor_strings(a: string, b: string): string
  local result: {string} = {}
  for i = 1, #a do
    result[i] = string.char(a:byte(i) ~ b:byte(i))
  end
  return table.concat(result)
end

--- HMAC-SHA256 using ipad/opad construction (RFC 2104).
--- @param key string The HMAC key (any length)
--- @param msg string The message to authenticate
--- @return string 32-byte HMAC
local function hmac_sha256(key: string, msg: string): string
  -- If key is longer than block size, hash it first
  local k: string
  if #key > BLOCK_SIZE then
    k = cosmo.Sha256(key)
  else
    k = key
  end
  -- Pad key to block size
  k = k .. string.rep("\0", BLOCK_SIZE - #k)
  -- Compute ipad and opad
  local ipad: {string} = {}
  local opad: {string} = {}
  for i = 1, BLOCK_SIZE do
    ipad[i] = string.char(k:byte(i) ~ 0x36)
    opad[i] = string.char(k:byte(i) ~ 0x5c)
  end
  local ikey = table.concat(ipad)
  local okey = table.concat(opad)
  -- H(okey || H(ikey || msg))
  return cosmo.Sha256(okey .. cosmo.Sha256(ikey .. msg))
end

--- HKDF-Expand (RFC 5869 §2.3).
--- Expands a pseudorandom key into output key material of the desired length.
--- @param prk string Pseudorandom key (≥32 bytes)
--- @param info string Context string
--- @param len number Desired output length (bytes), must be ≤ 255 * 32
--- @return string Output key material of length `len`
local function hkdf_expand(prk: string, info: string, len: number): string
  local okm: {string} = {}
  local t = ""
  local n = math.ceil(len / HMAC_LEN)
  for i = 1, n do
    t = hmac_sha256(prk, t .. info .. string.char(i))
    okm[#okm + 1] = t
  end
  return table.concat(okm):sub(1, len as integer)
end

--- SHA256-CTR stream keystream: generates `len` bytes of keystream
--- by hashing (key || nonce || counter) in 32-byte blocks.
--- @param key string 32-byte encryption key
--- @param nonce string 12-byte nonce
--- @param len number Desired keystream length
--- @return string Keystream bytes of length `len`
local function sha256_ctr_keystream(key: string, nonce: string, len: number): string
  local blocks: {string} = {}
  local n = math.ceil(len / 32)
  for i = 0, n - 1 do
    -- 4-byte little-endian counter
    local ctr = string.char(
      i % 256,
      math.floor(i / 256) % 256,
      math.floor(i / 65536) % 256,
      math.floor(i / 16777216) % 256
    )
    blocks[#blocks + 1] = cosmo.Sha256(key .. nonce .. ctr)
  end
  return table.concat(blocks):sub(1, len as integer)
end

--- Encrypt plaintext with the given key using SHA256-CTR + HMAC-SHA256 (Encrypt-then-MAC).
--- Output format: nonce(12) || ciphertext(#plaintext) || hmac(32)
--- @param plaintext string The data to encrypt
--- @param key string Encryption key (any length; will be key-derived via HKDF)
--- @return string? Ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if type(plaintext) ~= "string" then
    return nil, "plaintext must be a string"
  end
  if type(key) ~= "string" or #key == 0 then
    return nil, "key must be a non-empty string"
  end
  -- Derive separate encryption and MAC keys via HKDF
  local enc_key = hkdf_expand(key, "cosmic.crypto.enc", KEY_LEN)
  local mac_key = hkdf_expand(key, "cosmic.crypto.mac", KEY_LEN)
  -- Generate random nonce
  local nonce = rand.bytes(NONCE_LEN)
  -- Encrypt using SHA256-CTR
  local keystream = sha256_ctr_keystream(enc_key, nonce, #plaintext)
  local ciphertext: string
  if #plaintext == 0 then
    ciphertext = ""
  else
    ciphertext = xor_strings(plaintext, keystream)
  end
  -- Authenticate nonce || ciphertext
  local mac = hmac_sha256(mac_key, nonce .. ciphertext)
  return nonce .. ciphertext .. mac
end

--- Decrypt ciphertext with the given key.
--- Verifies the HMAC before decrypting. Returns nil + error on authentication failure.
--- @param data string The ciphertext (from encrypt())
--- @param key string The same key used for encryption
--- @return string? Plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt(data: string, key: string): string, string
  if type(data) ~= "string" then
    return nil, "data must be a string"
  end
  if type(key) ~= "string" or #key == 0 then
    return nil, "key must be a non-empty string"
  end
  -- Minimum length: nonce(12) + hmac(32) = 44 bytes
  if #data < NONCE_LEN + HMAC_LEN then
    return nil, "ciphertext too short"
  end
  -- Derive the same keys
  local enc_key = hkdf_expand(key, "cosmic.crypto.enc", KEY_LEN)
  local mac_key = hkdf_expand(key, "cosmic.crypto.mac", KEY_LEN)
  -- Split fields: nonce || ciphertext || mac
  local nonce = data:sub(1, NONCE_LEN)
  local mac = data:sub(#data - HMAC_LEN + 1)
  local ciphertext = data:sub(NONCE_LEN + 1, #data - HMAC_LEN)
  -- Verify MAC
  local expected_mac = hmac_sha256(mac_key, nonce .. ciphertext)
  if mac ~= expected_mac then
    return nil, "authentication failed"
  end
  -- Decrypt
  if #ciphertext == 0 then
    return ""
  end
  local keystream = sha256_ctr_keystream(enc_key, nonce, #ciphertext)
  return xor_strings(ciphertext, keystream)
end

--- Derive a 32-byte key from a password using Argon2id.
--- @param password string The password
--- @param salt string 16-byte salt
--- @return string? 32-byte raw key, or nil on error
--- @return string? Error message if derivation failed
local function derive_key_from_password(password: string, salt: string): string, string
  local encoded, err = argon2.hash_encoded(password, salt, {
      m_cost = 65536,
      t_cost = 3,
      parallelism = 1,
      hash_len = 32,
    }) as(string, any)
  if not encoded then
    return nil, tostring(err or "argon2 failed")
  end
  -- Extract base64 hash from PHC string: last $-delimited segment
  local b64 = encoded:match("([^$]+)$")
  if not b64 then
    return nil, "failed to parse argon2 output"
  end
  -- argon2 uses unpadded base64; add padding if needed
  local padded = b64 .. string.rep("=", (4 - #b64 % 4) % 4)
  local raw = cosmo.DecodeBase64(padded)
  if not raw or #raw ~= 32 then
    return nil, "failed to decode argon2 key"
  end
  return raw
end

--- Encrypt plaintext using a password (derives key via Argon2id).
--- Output format: salt(16) || encrypt(plaintext, derived_key)
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @return string? Ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  if type(password) ~= "string" or #password == 0 then
    return nil, "password must be a non-empty string"
  end
  local salt = rand.bytes(SALT_LEN)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end
  local ct, cerr = encrypt(plaintext, key)
  if not ct then
    return nil, cerr
  end
  return salt .. ct
end

--- Decrypt ciphertext using a password (derives key via Argon2id).
--- @param data string The ciphertext (from encrypt_with_password())
--- @param password string The password used for encryption
--- @return string? Plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt_with_password(data: string, password: string): string, string
  if type(data) ~= "string" then
    return nil, "data must be a string"
  end
  if type(password) ~= "string" or #password == 0 then
    return nil, "password must be a non-empty string"
  end
  -- Minimum: salt(16) + nonce(12) + hmac(32) = 60 bytes
  if #data < SALT_LEN + NONCE_LEN + HMAC_LEN then
    return nil, "ciphertext too short"
  end
  local salt = data:sub(1, SALT_LEN)
  local ct = data:sub(SALT_LEN + 1)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end
  return decrypt(ct, key)
end

local record CryptoModule
  encrypt: function(plaintext: string, key: string): string, string
  decrypt: function(data: string, key: string): string, string
  encrypt_with_password: function(plaintext: string, password: string): string, string
  decrypt_with_password: function(data: string, password: string): string, string
end

local M: CryptoModule = {
  encrypt = encrypt,
  decrypt = decrypt,
  encrypt_with_password = encrypt_with_password,
  decrypt_with_password = decrypt_with_password,
}

return M
