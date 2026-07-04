--- Symmetric encryption utilities.
--- Implements authenticated encryption using HMAC-SHA256 + SHA256-CTR stream cipher.
--- This is a best-effort construction using available cosmo primitives.
---
--- Security notes:
--- - SHA256-CTR is a PRF-based stream cipher. ChaCha20-Poly1305 or AES-GCM
---   would be preferable but are not available in cosmo.
--- - Password key derivation uses HKDF-SHA256 for clean raw-byte output.
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
    local block = cosmo.Sha256(enc_key .. nonce .. string.pack(">I8", counter))
    counter = counter + 1
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

-- Compare two strings in constant time to prevent timing attacks.
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
  -- HKDF-expand: one block is enough for 32 bytes
  local key = hmac_sha256(prk, "cosmic.crypto v1\x01")
  return key
end

--- Encrypt plaintext with a 32-byte key.
--- Uses SHA256-CTR + HMAC-SHA256 (Encrypt-then-MAC).
--- Wire format: nonce(16) || tag(32) || ciphertext.
--- @param plaintext string the data to encrypt
--- @param key string a 32-byte encryption key
--- @return string? the encrypted data, or nil on error
--- @return string? error message if encryption failed
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
--- @param data string the encrypted data (nonce || tag || ciphertext)
--- @param key string a 32-byte encryption key
--- @return string? the decrypted plaintext, or nil on error
--- @return string? error message if decryption or authentication failed
local function decrypt(data: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be exactly 32 bytes, got " .. #key
  end
  if #data < NONCE_LEN + HASH_LEN then
    return nil, "ciphertext too short"
  end
  local nonce = data:sub(1, NONCE_LEN)
  local tag = data:sub(NONCE_LEN + 1, NONCE_LEN + HASH_LEN)
  local ciphertext = data:sub(NONCE_LEN + HASH_LEN + 1)
  local enc_key, mac_key = derive_keys(key)
  local expected_tag = hmac_sha256(mac_key, nonce .. ciphertext)
  if not ct_equal(tag, expected_tag) then
    return nil, "authentication failed"
  end
  return sha256_ctr(enc_key, nonce, ciphertext)
end

--- Encrypt plaintext with a password using HKDF-SHA256 key derivation.
--- Wire format: pwsalt(16) || nonce(16) || tag(32) || ciphertext.
--- @param plaintext string the data to encrypt
--- @param password string the password for key derivation
--- @return string? the encrypted data, or nil on error
--- @return string? error message if encryption failed
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
--- @param data string the encrypted data (pwsalt || nonce || tag || ciphertext)
--- @param password string the password for key derivation
--- @return string? the decrypted plaintext, or nil on error
--- @return string? error message if decryption or authentication failed
local function decrypt_with_password(data: string, password: string): string, string
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
