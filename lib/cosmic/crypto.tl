--- Symmetric encryption utilities.
--- Implements authenticated encryption using HMAC-SHA256 + SHA256-CTR stream cipher.
--- This is a best-effort construction using available cosmo primitives.
---
--- Security notes:
--- - MAC comparison uses Lua string equality (not constant-time). Avoid in
---   high-security contexts requiring timing-attack resistance.
--- - SHA256-CTR is a PRF-based stream cipher. The right choice would be
---   ChaCha20-Poly1305 or AES-GCM, but those are not available in cosmo.
--- - Password key derivation uses HKDF-SHA256, not Argon2, because argon2
---   only exposes encoded strings (not raw bytes).
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local key = require("cosmic.rand").bytes(32)
---   local ct, err = crypto.encrypt("hello", key)
---   local pt, err = crypto.decrypt(ct, key)
---   local ct, err = crypto.encrypt_with_password("hello", "my password")
---   local pt, err = crypto.decrypt_with_password(ct, "my password")
local cosmo = require("cosmo")
local rand = require("cosmic.rand")

-- HMAC-SHA256 block size and output size
local BLOCK = 64
local HASH_LEN = 32
local KEY_LEN = 32
local NONCE_LEN = 16

-- Compute HMAC-SHA256(key, msg).
-- key and msg are raw byte strings.
local function hmac_sha256(key: string, msg: string): string
  -- Normalize key to block size
  local k = key
  if #k > BLOCK then
    k = cosmo.Sha256(k)
  end
  -- Pad key to block size
  local ipad_parts: {string} = {}
  local opad_parts: {string} = {}
  for i = 1, BLOCK do
    local b = (i <= #k) and string.byte(k, i) or 0
    ipad_parts[i] = string.char(b ~ 0x36)
    opad_parts[i] = string.char(b ~ 0x5c)
  end
  local ipad = table.concat(ipad_parts)
  local opad = table.concat(opad_parts)
  local inner = cosmo.Sha256(ipad .. msg)
  return cosmo.Sha256(opad .. inner)
end

-- SHA256-CTR stream cipher: XOR data with keystream derived from enc_key + nonce.
-- enc_key: 32-byte encryption key
-- nonce: 16-byte nonce
-- data: plaintext or ciphertext
local function sha256_ctr(enc_key: string, nonce: string, data: string): string
  local out: {string} = {}
  local pos = 1
  local counter = 0
  while pos <= #data do
    -- Generate 32-byte keystream block
    local block = cosmo.Sha256(enc_key .. nonce .. string.pack(">I8", counter))
    counter = counter + 1
    -- XOR data bytes with keystream bytes
    local chunk_parts: {string} = {}
    local block_len = #block
    local i = 1
    while pos <= #data and i <= block_len do
      local db = string.byte(data, pos)
      local kb = string.byte(block, i)
      chunk_parts[i] = string.char(db ~ kb)
      pos = pos + 1
      i = i + 1
    end
    out[#out + 1] = table.concat(chunk_parts)
  end
  return table.concat(out)
end

-- Derive enc_key and mac_key from a 32-byte root key.
local function derive_keys(key: string): string, string
  local enc_key = hmac_sha256(key, "enc")
  local mac_key = hmac_sha256(key, "mac")
  return enc_key, mac_key
end

-- Derive a 32-byte key from a password and a 16-byte salt using HKDF-SHA256.
local function derive_key_from_password(password: string, salt: string): string
  -- HKDF-extract: PRK = HMAC-SHA256(salt, password)
  local prk = hmac_sha256(salt, password)
  -- HKDF-expand: key = HMAC-SHA256(PRK, info || 0x01) — one block is enough for 32 bytes
  local key = hmac_sha256(prk, "cosmic.crypto v1\x01")
  return key
end

--- Encrypt plaintext with a 32-byte key using SHA256-CTR + HMAC-SHA256 (Encrypt-then-MAC).
--- Returns ciphertext as a binary string: nonce(16) || tag(32) || ciphertext.
--- @param plaintext string The data to encrypt
--- @param key string A 32-byte encryption key
--- @return string? The encrypted data, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  local nonce = rand.bytes(NONCE_LEN)
  local enc_key, mac_key = derive_keys(key)
  local ciphertext = sha256_ctr(enc_key, nonce, plaintext)
  local tag = hmac_sha256(mac_key, nonce .. ciphertext)
  return nonce .. tag .. ciphertext
end

--- Decrypt data encrypted with encrypt().
--- @param data string The encrypted data (nonce || tag || ciphertext)
--- @param key string A 32-byte encryption key
--- @return string? The decrypted plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt(data: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  -- minimum: nonce(16) + tag(32) + 0 bytes plaintext = 48
  if #data < NONCE_LEN + HASH_LEN then
    return nil, "ciphertext too short"
  end
  local nonce = data:sub(1, NONCE_LEN)
  local tag = data:sub(NONCE_LEN + 1, NONCE_LEN + HASH_LEN)
  local ciphertext = data:sub(NONCE_LEN + HASH_LEN + 1)
  local enc_key, mac_key = derive_keys(key)
  local expected_tag = hmac_sha256(mac_key, nonce .. ciphertext)
  if tag ~= expected_tag then
    return nil, "authentication failed"
  end
  return sha256_ctr(enc_key, nonce, ciphertext)
end

--- Encrypt plaintext with a password using HKDF-SHA256 key derivation.
--- Returns ciphertext as: pwsalt(16) || nonce(16) || tag(32) || ciphertext.
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @return string? The encrypted data, or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  local pwsalt = rand.bytes(NONCE_LEN)
  local key = derive_key_from_password(password, pwsalt)
  local inner, err = encrypt(plaintext, key)
  if not inner then
    return nil, err
  end
  return pwsalt .. inner
end

--- Decrypt data encrypted with encrypt_with_password().
--- @param data string The encrypted data (pwsalt || nonce || tag || ciphertext)
--- @param password string The password for key derivation
--- @return string? The decrypted plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt_with_password(data: string, password: string): string, string
  -- minimum: pwsalt(16) + nonce(16) + tag(32) = 64
  if #data < NONCE_LEN + NONCE_LEN + HASH_LEN then
    return nil, "ciphertext too short"
  end
  local pwsalt = data:sub(1, NONCE_LEN)
  local inner = data:sub(NONCE_LEN + 1)
  local key = derive_key_from_password(password, pwsalt)
  return decrypt(inner, key)
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
