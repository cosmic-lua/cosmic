--- Symmetric encryption and authenticated decryption.
--- Implements authenticated symmetric encryption using SHA-256 CTR + HMAC
--- construction with Argon2id password-based key derivation.
---
--- Construction: SHA-256 counter-mode stream cipher with Encrypt-then-MAC.
---   - enc_key = sha256("enc:" || key) -- 32-byte encryption sub-key
---   - mac_key = sha256("mac:" || key) -- 32-byte authentication sub-key
---   - keystream block i: sha256(enc_key || nonce || i_4be)
---   - tag: sha256(mac_key || nonce || len_4be || ciphertext)
---   - wire: nonce(16) || ciphertext_len(4 big-endian) || ciphertext || tag(32)
---
--- Note: string comparison for tag verification is not constant-time.
--- This is acceptable for a pure-Lua implementation. Do not use in
--- contexts where timing side-channels are a critical threat model.
---
--- Note: maximum plaintext size is 2^32 * 32 bytes (~128 GiB) due to the
--- 32-bit block counter.
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local ct, err = crypto.encrypt("secret", key)
---   local pt, err = crypto.decrypt(ct, key)
---   local ct, err = crypto.encrypt_with_password("secret", "password")
---   local pt, err = crypto.decrypt_with_password(ct, "password")
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local rand = require("cosmic.rand")

-- Minimum overhead: 16-byte nonce + 4-byte len + 32-byte tag = 52 bytes
local MIN_BLOB_LEN < const > = 52
-- Salt prefix for password-based encryption: 16 bytes
local PWD_SALT_LEN < const > = 16

-- Pack a 32-bit unsigned integer as a 4-byte big-endian string.
local function pack_u32_be(n: integer): string
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256
  )
end

-- Unpack a 4-byte big-endian string to a 32-bit unsigned integer.
local function unpack_u32_be(s: string, offset: integer): integer
  local b1, b2, b3, b4 = s:byte(offset, offset + 3)
  return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- XOR two equal-length strings byte-by-byte.
-- Returns the XOR'd result.
local function xor_strings(a: string, b: string): string
  local result: {string} = {}
  for i = 1, #a do
    local ba, bb = a:byte(i), b:byte(i)
    result[i] = string.char(ba ~ bb)
  end
  return table.concat(result)
end

-- Compute a keystream block for the given enc_key, nonce, and counter.
-- Returns 32 bytes of keystream.
local function keystream_block(enc_key: string, nonce: string, counter: integer): string
  return cosmo.Sha256(enc_key .. nonce .. pack_u32_be(counter))
end

-- Derive enc_key and mac_key from a raw key using domain-separated SHA-256.
local function derive_keys(key: string): string, string
  local enc_key = cosmo.Sha256("enc:" .. key)
  local mac_key = cosmo.Sha256("mac:" .. key)
  return enc_key, mac_key
end

-- Stream-cipher data using enc_key and nonce.
-- Works for both encryption and decryption (XOR is its own inverse).
local function stream_cipher(data: string, enc_key: string, nonce: string): string
  if #data == 0 then
    return ""
  end
  local blocks: {string} = {}
  local counter = 0
  local offset = 1
  while offset <= #data do
    local block_end = math.min(offset + 31, #data)
    local chunk_len = block_end - offset + 1
    local ks = keystream_block(enc_key, nonce, counter)
    if chunk_len < 32 then
      -- Partial block: XOR only the needed bytes
      blocks[#blocks + 1] = xor_strings(data:sub(offset, block_end), ks:sub(1, chunk_len))
    else
      blocks[#blocks + 1] = xor_strings(data:sub(offset, block_end), ks)
    end
    offset = offset + 32
    counter = counter + 1
  end
  return table.concat(blocks)
end

--- Encrypt plaintext with a symmetric key.
--- Returns an authenticated ciphertext blob.
--- The key may be any length; sub-keys are derived via SHA-256.
--- @param plaintext string Data to encrypt
--- @param key string Encryption key (any length; 32+ bytes recommended)
--- @return string? Ciphertext blob (nonce || len || ciphertext || tag), or nil on error
--- @return string? Error message if encryption failed
local function encrypt(plaintext: string, key: string): string, string
  if not plaintext then
    return nil, "plaintext is required"
  end
  if not key or #key == 0 then
    return nil, "key is required"
  end

  local nonce = rand.bytes(16)
  local enc_key, mac_key = derive_keys(key)

  local ciphertext = stream_cipher(plaintext, enc_key, nonce)
  local ct_len = #ciphertext
  local len_bytes = pack_u32_be(ct_len)

  -- Encrypt-then-MAC: tag covers nonce + length + ciphertext
  local tag = cosmo.Sha256(mac_key .. nonce .. len_bytes .. ciphertext)

  return nonce .. len_bytes .. ciphertext .. tag, nil
end

--- Decrypt a ciphertext blob produced by encrypt().
--- Returns the original plaintext on success, nil and an error message on failure.
--- @param blob string Ciphertext blob from encrypt()
--- @param key string Encryption key (must match the key used for encryption)
--- @return string? Plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt(blob: string, key: string): string, string
  if not blob then
    return nil, "ciphertext is required"
  end
  if not key or #key == 0 then
    return nil, "key is required"
  end
  if #blob < MIN_BLOB_LEN then
    return nil, "ciphertext too short"
  end

  -- Parse wire format: nonce(16) || len(4) || ciphertext || tag(32)
  local nonce = blob:sub(1, 16)
  local ct_len = unpack_u32_be(blob, 17)
  local expected_total = 16 + 4 + ct_len + 32
  if #blob ~= expected_total then
    return nil, "ciphertext length mismatch"
  end

  local ciphertext = blob:sub(21, 20 + ct_len)
  local tag = blob:sub(21 + ct_len)

  local enc_key, mac_key = derive_keys(key)

  -- Verify tag before decrypting (Encrypt-then-MAC)
  local len_bytes = pack_u32_be(ct_len)
  local expected_tag = cosmo.Sha256(mac_key .. nonce .. len_bytes .. ciphertext)
  if tag ~= expected_tag then
    return nil, "authentication failed"
  end

  local plaintext = stream_cipher(ciphertext, enc_key, nonce)
  return plaintext, nil
end

-- Derive a 32-byte key from a password and salt using Argon2id.
-- Uses conservative parameters for security.
local function derive_key_from_password(password: string, salt: string): string, string
  local config: argon2.Config = {
    m_cost = 65536,
    t_cost = 3,
    parallelism = 1,
    hash_len = 32,
  }
  local encoded, err = argon2.hash_encoded(password, salt, config) as(string, string)
  if not encoded then
    return nil, "key derivation failed: " .. tostring(err)
  end
  -- Condense PHC string to a 32-byte key
  return cosmo.Sha256(encoded), nil
end

--- Encrypt plaintext using a password.
--- Derives an encryption key from the password using Argon2id (m=64MiB, t=3).
--- Returns an authenticated ciphertext blob with embedded Argon2 salt.
--- WARNING: This function is slow by design (Argon2id key stretching).
--- @param plaintext string Data to encrypt
--- @param password string Password for key derivation
--- @return string? Ciphertext blob (argon2_salt(16) || encrypt(plaintext, key)), or nil
--- @return string? Error message if encryption failed
local function encrypt_with_password(plaintext: string, password: string): string, string
  if not plaintext then
    return nil, "plaintext is required"
  end
  if not password then
    return nil, "password is required"
  end

  local salt = rand.bytes(PWD_SALT_LEN)
  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end

  local blob, err2 = encrypt(plaintext, key)
  if not blob then
    return nil, err2
  end

  return salt .. blob, nil
end

--- Decrypt a ciphertext produced by encrypt_with_password().
--- Derives the decryption key from the password using Argon2id.
--- WARNING: This function is slow by design (Argon2id key stretching).
--- @param blob string Ciphertext blob from encrypt_with_password()
--- @param password string Password used for encryption
--- @return string? Plaintext, or nil on error
--- @return string? Error message if decryption or authentication failed
local function decrypt_with_password(blob: string, password: string): string, string
  if not blob then
    return nil, "ciphertext is required"
  end
  if not password then
    return nil, "password is required"
  end
  if #blob < PWD_SALT_LEN + MIN_BLOB_LEN then
    return nil, "ciphertext too short"
  end

  local salt = blob:sub(1, PWD_SALT_LEN)
  local inner_blob = blob:sub(PWD_SALT_LEN + 1)

  local key, err = derive_key_from_password(password, salt)
  if not key then
    return nil, err
  end

  return decrypt(inner_blob, key)
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
