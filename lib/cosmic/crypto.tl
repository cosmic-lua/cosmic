--- Cryptographic utilities.
--- Wraps cosmo.Sha256, cosmo.GetRandomBytes, and cosmo.argon2 for common crypto operations.
---
--- Example usage:
---   local crypto = require("cosmic.crypto")
---   local hash = crypto.sha256_hex("hello")
---   local random = crypto.random_bytes(32)
---   local encoded = crypto.password_hash("password123")
---   local valid = crypto.password_verify(encoded, "password123")
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")

--- Options for password hashing with Argon2.
--- All fields are optional and have sensible defaults.
local record HashOptions
  --- Memory cost in kibibytes (default: 4096, i.e. 4 MiB)
  m_cost: number
  --- Time cost / iterations (default: 3)
  t_cost: number
  --- Parallelism factor (default: 1)
  parallelism: number
  --- Output hash length in bytes (default: 32)
  hash_len: number
  --- Variant: "argon2id" (default), "argon2i", or "argon2d"
  variant: string
end

-- Map variant string names to argon2 variant constants
local variant_map: {string:argon2.Variant} = {
  argon2id = argon2.variants.argon2_id,
  argon2i = argon2.variants.argon2_i,
  argon2d = argon2.variants.argon2_d,
}

--- Compute SHA-256 hash of data.
--- Returns raw bytes (32 bytes).
--- @param data string The data to hash
--- @return string The SHA-256 hash as raw bytes
local function sha256(data: string): string
  return cosmo.Sha256(data)
end

--- Compute SHA-256 hash of data and return as hex string.
--- Returns a 64-character lowercase hex string.
--- @param data string The data to hash
--- @return string The SHA-256 hash as a hex string
local function sha256_hex(data: string): string
  return cosmo.EncodeHex(cosmo.Sha256(data)):lower()
end

--- Generate cryptographically secure random bytes.
--- @param n number The number of random bytes to generate
--- @return string Random bytes
local function random_bytes(n: number): string
  return cosmo.GetRandomBytes(n)
end

--- Hash a password using Argon2.
--- Returns an encoded string suitable for storage.
--- @param password string The password to hash
--- @param options HashOptions? Optional configuration for the hash
--- @return string? The encoded hash string, or nil on error
--- @return string? Error message if hashing failed
local function password_hash(password: string, options?: HashOptions): string, string
  -- Generate a random salt (16 bytes is recommended)
  local salt = cosmo.GetRandomBytes(16)

  -- Build config from options
  local config: argon2.Config = {}
  if options then
    if options.m_cost then config.m_cost = options.m_cost end
    if options.t_cost then config.t_cost = options.t_cost end
    if options.parallelism then config.parallelism = options.parallelism end
    if options.hash_len then config.hash_len = options.hash_len end
    if options.variant then
      local v = variant_map[options.variant]
      if v then
        config.variant = v
      else
        return nil, "invalid variant: " .. options.variant .. " (expected argon2id, argon2i, or argon2d)"
      end
    end
  end

  local encoded, err = argon2.hash_encoded(password, salt, config) as (string, any)
  if not encoded then
    return nil, tostring(err or "failed to hash password")
  end
  return encoded
end

--- Verify a password against an Argon2 encoded hash.
--- @param encoded string The encoded hash string (from password_hash)
--- @param password string The password to verify
--- @return boolean True if the password matches
local function password_verify(encoded: string, password: string): boolean
  local ok = argon2.verify(encoded, password)
  return ok == true
end

local record CryptoModule
  type HashOptions = HashOptions

  sha256: function(data: string): string
  sha256_hex: function(data: string): string
  random_bytes: function(n: number): string
  password_hash: function(password: string, options?: HashOptions): string, string
  password_verify: function(encoded: string, password: string): boolean
end

local M: CryptoModule = {
  sha256 = sha256,
  sha256_hex = sha256_hex,
  random_bytes = random_bytes,
  password_hash = password_hash,
  password_verify = password_verify,
}

return M
