--- Symmetric encryption utilities.
--- Provides AES-256-CTR + HMAC-SHA256 authenticated encryption with optional
--- Argon2id password-based key derivation.
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local key = require("cosmic.rand").bytes(32)
---   local ct, err = crypto.encrypt("hello", key)
---   local pt, err = crypto.decrypt(ct, key)
---
---   local ct2, err = crypto.encrypt_with_password("hello", "pass")
---   local pt2, err = crypto.decrypt_with_password(ct2, "pass")
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- AES S-box
local SBOX: {integer} = {
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5,
  0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
  0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc,
  0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a,
  0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
  0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b,
  0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85,
  0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
  0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17,
  0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88,
  0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
  0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9,
  0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6,
  0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
  0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94,
  0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68,
  0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
}

-- AES round constants
local RCON: {integer} = {
  0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
}

-- GF(2^8) multiply by 2
local function xtime(b: integer): integer
  if b & 0x80 ~= 0 then
    return ((b << 1) & 0xff) ~ 0x1b
  end
  return (b << 1) & 0xff
end

-- Expand 32-byte key into 15 round keys (each 16 bytes as 4 words of 4 bytes)
local function key_schedule(key: string): {{integer}}
  local w: {{integer}} = {}
  for i = 1, 8 do
    local off = (i - 1) * 4 + 1
    w[i] = {
      key:byte(off),
      key:byte(off + 1),
      key:byte(off + 2),
      key:byte(off + 3),
    }
  end
  for i = 9, 60 do
    local prev = w[i - 1]
    local t: {integer}
    if (i - 1) % 8 == 0 then
      -- RotWord + SubWord + Rcon
      local rcon_idx = ((i - 1) // 8)
      t = {
        SBOX[prev[2] + 1] ~ RCON[rcon_idx],
        SBOX[prev[3] + 1],
        SBOX[prev[4] + 1],
        SBOX[prev[1] + 1],
      }
    elseif (i - 1) % 8 == 4 then
      t = {SBOX[prev[1] + 1], SBOX[prev[2] + 1], SBOX[prev[3] + 1], SBOX[prev[4] + 1]}
    else
      t = {prev[1], prev[2], prev[3], prev[4]}
    end
    local wim8 = w[i - 8]
    w[i] = {wim8[1] ~ t[1], wim8[2] ~ t[2], wim8[3] ~ t[3], wim8[4] ~ t[4]}
  end
  -- Build 15 round keys (each = 4 words = 16 bytes as int array)
  local rks: {{integer}} = {}
  for r = 0, 14 do
    local rk: {integer} = {}
    for wi = 1, 4 do
      local word = w[r * 4 + wi]
      rk[(wi - 1) * 4 + 1] = word[1]
      rk[(wi - 1) * 4 + 2] = word[2]
      rk[(wi - 1) * 4 + 3] = word[3]
      rk[(wi - 1) * 4 + 4] = word[4]
    end
    rks[r + 1] = rk
  end
  return rks
end

-- XOR 16-byte state with round key
local function add_round_key(s: {integer}, rk: {integer}): {integer}
  for i = 1, 16 do s[i] = s[i] ~ rk[i] end
  return s
end

-- SubBytes
local function sub_bytes(s: {integer}): {integer}
  for i = 1, 16 do s[i] = SBOX[s[i] + 1] end
  return s
end

-- ShiftRows
local function shift_rows(s: {integer}): {integer}
  -- row0: unchanged; row1: shift left 1; row2: shift left 2; row3: shift left 3
  -- State is column-major: s[col*4+row+1]
  local t = s[2]; s[2] = s[6]; s[6] = s[10]; s[10] = s[14]; s[14] = t
  t = s[3]; s[3] = s[11]; s[11] = t; t = s[7]; s[7] = s[15]; s[15] = t
  t = s[4]; s[4] = s[16]; s[16] = s[12]; s[12] = s[8]; s[8] = t
  return s
end

-- MixColumns
local function mix_columns(s: {integer}): {integer}
  for c = 0, 3 do
    local i = c * 4 + 1
    local a0, a1, a2, a3 = s[i], s[i + 1], s[i + 2], s[i + 3]
    s[i] = xtime(a0) ~ xtime(a1) ~ a1 ~ a2 ~ a3
    s[i + 1] = a0 ~ xtime(a1) ~ xtime(a2) ~ a2 ~ a3
    s[i + 2] = a0 ~ a1 ~ xtime(a2) ~ xtime(a3) ~ a3
    s[i + 3] = xtime(a0) ~ a0 ~ a1 ~ a2 ~ xtime(a3)
  end
  return s
end

-- Encrypt one 16-byte block (as byte array) with AES-256
local function aes_block(block: {integer}, rks: {{integer}}): {integer}
  local s: {integer} = {}
  for i = 1, 16 do s[i] = block[i] end
  s = add_round_key(s, rks[1])
  for r = 2, 14 do
    s = sub_bytes(s)
    s = shift_rows(s)
    s = mix_columns(s)
    s = add_round_key(s, rks[r])
  end
  s = sub_bytes(s)
  s = shift_rows(s)
  s = add_round_key(s, rks[15])
  return s
end

-- Generate CTR keystream for `length` bytes starting from nonce (16 bytes big-endian counter)
local function ctr_stream(rks: {{integer}}, nonce: string, length: integer): string
  local out: {string} = {}
  local ctr = {nonce:byte(1, 16)}
  local pos = 0
  while pos < length do
    local ks = aes_block(ctr, rks)
    for i = 1, math.min(16, length - pos) do
      out[#out + 1] = string.char(ks[i])
    end
    pos = pos + 16
    -- Increment big-endian counter
    for i = 16, 1, -1 do
      ctr[i] = (ctr[i] + 1) & 0xff
      if ctr[i] ~= 0 then break end
    end
  end
  return table.concat(out)
end

-- XOR two byte strings of equal length
local function xor_bytes(a: string, b: string): string
  local out: {string} = {}
  for i = 1, #a do
    out[i] = string.char(a:byte(i) ~ b:byte(i))
  end
  return table.concat(out)
end

-- HMAC-SHA256 using cosmo.Sha256 (raw 32-byte output, 64-byte block)
local function hmac_sha256(key: string, data: string): string
  local BLOCK = 64
  -- key is already 32 bytes so no pre-hashing needed; pad to block size
  local k = key .. string.rep("\x00", BLOCK - #key)
  local ipad = ""
  local opad = ""
  for i = 1, BLOCK do
    ipad = ipad .. string.char(k:byte(i) ~ 0x36)
    opad = opad .. string.char(k:byte(i) ~ 0x5c)
  end
  return cosmo.Sha256(opad .. cosmo.Sha256(ipad .. data))
end

-- HKDF-Expand: derive `length` bytes from prk using info label
local function hkdf_expand(prk: string, info: string, length: integer): string
  local out = ""
  local t = ""
  local i = 1
  while #out < length do
    t = hmac_sha256(prk, t .. info .. string.char(i))
    out = out .. t
    i = i + 1
  end
  return out:sub(1, length)
end

-- Constant-time byte comparison (returns true if equal)
local function ct_equal(a: string, b: string): boolean
  if #a ~= #b then return false end
  local acc = 0
  for i = 1, #a do acc = acc | (a:byte(i) ~ b:byte(i)) end
  return acc == 0
end

local VERSION_KEY = "\x01"
local VERSION_PWD = "\x02"
local NONCE_LEN = 16
local HMAC_LEN = 32
local KEY_LEN = 32
local SALT_LEN = 16
-- Minimum ciphertext length for version \x01: version(1) + nonce(16) + hmac(32) = 49
local MIN_CT_LEN = 1 + NONCE_LEN + HMAC_LEN

--- Encrypt plaintext with a 32-byte key using AES-256-CTR + HMAC-SHA256.
--- Returns binary ciphertext or nil + error.
--- @param plaintext string The data to encrypt
--- @param key string A 32-byte encryption key
--- @return string? Encrypted ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be 32 bytes, got " .. #key
  end
  local nonce = rand.bytes(NONCE_LEN)
  local enc_key = hkdf_expand(key, "enc", KEY_LEN)
  local mac_key = hkdf_expand(key, "mac", KEY_LEN)
  local rks = key_schedule(enc_key)
  local ks = ctr_stream(rks, nonce, #plaintext)
  local ct = xor_bytes(plaintext, ks)
  local mac = hmac_sha256(mac_key, nonce .. ct)
  return VERSION_KEY .. nonce .. ct .. mac
end

--- Decrypt ciphertext produced by encrypt.
--- Returns plaintext or nil + error.
--- @param ciphertext string The encrypted data
--- @param key string A 32-byte encryption key
--- @return string? Decrypted plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt(ciphertext: string, key: string): string, string
  if #key ~= KEY_LEN then
    return nil, "key must be 32 bytes, got " .. #key
  end
  if #ciphertext < MIN_CT_LEN then
    return nil, "ciphertext too short"
  end
  if ciphertext:sub(1, 1) ~= VERSION_KEY then
    return nil, "unsupported ciphertext version"
  end
  local nonce = ciphertext:sub(2, 1 + NONCE_LEN)
  local mac = ciphertext:sub(#ciphertext - HMAC_LEN + 1)
  local ct = ciphertext:sub(2 + NONCE_LEN, #ciphertext - HMAC_LEN)
  local mac_key = hkdf_expand(key, "mac", KEY_LEN)
  local expected_mac = hmac_sha256(mac_key, nonce .. ct)
  if not ct_equal(mac, expected_mac) then
    return nil, "authentication failed: ciphertext has been tampered with"
  end
  local enc_key = hkdf_expand(key, "enc", KEY_LEN)
  local rks = key_schedule(enc_key)
  local ks = ctr_stream(rks, nonce, #ct)
  return xor_bytes(ct, ks)
end

-- Argon2id parameters for password-based key derivation
local ARGON2_M = 65536
local ARGON2_T = 3
local ARGON2_P = 1

local function derive_key_from_password(password: string, salt: string): string, string
  -- Derive a 32-byte key using Argon2id
  local encoded, err = argon2.hash_encoded(password, salt, {
      m_cost = ARGON2_M,
      t_cost = ARGON2_T,
      parallelism = ARGON2_P,
      hash_len = KEY_LEN,
      variant = argon2.variants.argon2_id,
    }) as(string, any)
  if not encoded then
    return nil, tostring(err or "argon2 failed")
  end
  -- Extract raw hash from encoded string "$argon2id$...$<base64hash>"
  -- The encoded format is: $argon2id$v=N$m=M,t=T,p=P$<salt_b64>$<hash_b64>
  local hash_b64 = encoded:match("%$([A-Za-z0-9+/=]+)$")
  if not hash_b64 then
    return nil, "failed to parse argon2 output"
  end
  -- Decode base64 to get raw bytes
  local key_bytes = cosmo.DecodeBase64(hash_b64)
  return key_bytes:sub(1, KEY_LEN)
end

--- Encrypt plaintext with a password using Argon2id key derivation + AES-256-CTR + HMAC-SHA256.
--- Returns binary ciphertext or nil + error.
--- @param plaintext string The data to encrypt
--- @param password string The password for key derivation
--- @return string? Encrypted ciphertext, or nil on error
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  local salt = rand.bytes(SALT_LEN)
  local key, kerr = derive_key_from_password(password, salt)
  if not key then
    return nil, kerr
  end
  local ct, cerr = encrypt(plaintext, key)
  if not ct then
    return nil, cerr
  end
  return VERSION_PWD .. salt .. ct
end

--- Decrypt ciphertext produced by encrypt_with_password.
--- Returns plaintext or nil + error.
--- @param ciphertext string The encrypted data
--- @param password string The password for key derivation
--- @return string? Decrypted plaintext, or nil on error
--- @return string? Error message if decryption failed
local function decrypt_with_password(ciphertext: string, password: string): string, string
  -- version(1) + salt(16) + inner ct (min 49) = min 66 bytes
  local min_len = 1 + SALT_LEN + MIN_CT_LEN
  if #ciphertext < min_len then
    return nil, "ciphertext too short"
  end
  if ciphertext:sub(1, 1) ~= VERSION_PWD then
    return nil, "unsupported ciphertext version"
  end
  local salt = ciphertext:sub(2, 1 + SALT_LEN)
  local inner = ciphertext:sub(2 + SALT_LEN)
  local key, kerr = derive_key_from_password(password, salt)
  if not key then
    return nil, kerr
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
