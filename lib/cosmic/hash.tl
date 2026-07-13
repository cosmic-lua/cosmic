--- Hash utilities.
--- Wraps cosmo.GetCryptoHash and cosmo.argon2 for digest, HMAC, and
--- password hashing.
---
--- Example usage:
---   local hash = require("cosmic.hash")
---   local digest = hash.sha256_hex("hello")
---   local d = hash.digest("sha512", "hello")
---   local tag = hash.hmac("sha256", "secret", "message")
---   local encoded = hash.password("password123")
---   local valid = hash.verify_password(encoded, "password123")
---
--- Digest and HMAC functions return raw bytes; hex-encode with
--- cosmic.codec.encode_hex if needed. For CRC-32 checksums, see
--- cosmic.codec.crc32. For random bytes, use cosmic.rand.bytes(n).
---
--- Reserved name: hash.new(algo): Hasher — a streaming digest object
--- API (update/final) is reserved for a post-stable battery. Do not
--- reuse this name for anything else.
local cosmo = require("cosmo")
local argon2 = require("cosmo.argon2")
local codec = require("cosmic.codec")

--- Digest algorithms accepted by digest and hmac.
local enum Algo
  "sha256"
  "sha512"
  "sha384"
  "sha224"
  "sha1"
  "md5"
  "blake2b256"
end

-- The exact algorithm set frozen at the stable cut. The C binding
-- resolves names case-insensitively and knows a few extra legacy
-- digests (MD2, MD4), so this wrapper-side check is load-bearing:
-- it keeps the runtime surface identical to the Algo enum.
local valid_algos: {string: boolean} = {
  sha256 = true,
  sha512 = true,
  sha384 = true,
  sha224 = true,
  sha1 = true,
  md5 = true,
  blake2b256 = true,
}

--- Options for password hashing with Argon2.
--- All fields are optional and have sensible defaults.
local record HashOptions
  --- Memory cost in kibibytes (default: 19456, i.e. 19 MiB per OWASP minimum)
  m_cost: number
  --- Time cost / iterations (default: 3)
  t_cost: number
  --- Parallelism factor (default: 1)
  parallelism: number
  --- Output hash length in bytes (default: 32)
  hash_len: number
  --- Variant: "argon2id" (default), "argon2i", or "argon2d"
  variant: argon2.Variant
end

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
  -- cosmo.EncodeHex (which encode_hex delegates to) already emits
  -- lowercase hex, so :lower() here was a dead full-string scan.
  return codec.encode_hex(cosmo.Sha256(data))
end

--- Compute a message digest of data with the given algorithm.
--- Returns raw bytes; hex-encode with cosmic.codec.encode_hex if
--- needed. For the common case, sha256 / sha256_hex are equivalent
--- conveniences. MD5 and SHA-1 are provided for interoperability with
--- existing formats only — do not use them for new security purposes.
--- @param algo Algo The digest algorithm
--- @param data string The data to hash
--- @return string | nil The digest as raw bytes, or nil on error
--- @return string? Error message if the algorithm is unknown
local function digest(algo: Algo, data: string): string | nil, string
  if not valid_algos[algo] then
    return nil, "unknown hash algorithm: " .. tostring(algo)
  end
  local d, err = cosmo.GetCryptoHash(algo, data)
  if not d then
    return nil, err as string
  end
  return d
end

--- Compute an HMAC (RFC 2104) of data with a secret key using the
--- given digest algorithm. Returns raw bytes; hex-encode with
--- cosmic.codec.encode_hex if needed. Compare MACs with
--- constant_time_equal, not ==. The key must be non-empty: the C
--- binding treats an empty key as "no key" and would silently compute
--- a plain digest instead of an HMAC.
--- @param algo Algo The digest algorithm
--- @param key string The secret key (must be non-empty)
--- @param data string The message to authenticate
--- @return string | nil The HMAC tag as raw bytes, or nil on error
--- @return string? Error message if the algorithm is unknown or the key is empty
local function hmac(algo: Algo, key: string, data: string): string | nil, string
  if not valid_algos[algo] then
    return nil, "unknown hash algorithm: " .. tostring(algo)
  end
  if #key == 0 then
    return nil, "hmac: key must be non-empty"
  end
  local d, err = cosmo.GetCryptoHash(algo, data, key)
  if not d then
    return nil, err as string
  end
  return d
end

--- Compute HMAC-SHA256 of data with a secret key (RFC 2104).
--- Returns raw bytes (32 bytes); hex-encode with cosmic.codec.encode_hex
--- if needed. Compare MACs with constant_time_equal, not ==.
--- @param key string The secret key
--- @param data string The message to authenticate
--- @return string The HMAC-SHA256 tag as raw bytes
local function hmac_sha256(key: string, data: string): string
  return (cosmo.GetCryptoHash("SHA256", data, key))
end

--- Compare two strings in constant time (for digests and MACs).
--- A plain == comparison exits at the first differing byte, leaking how
--- much of a secret an attacker has guessed; this XOR-accumulates over
--- every byte instead. Only the lengths are allowed to short-circuit
--- (digest/MAC lengths are public).
--- @param a string First string
--- @param b string Second string
--- @return boolean True when a and b are equal
local function constant_time_equal(a: string, b: string): boolean
  if #a ~= #b then
    return false
  end
  local acc = 0
  for i = 1, #a do
    acc = acc | (string.byte(a, i) ~ string.byte(b, i))
  end
  return acc == 0
end

--- Hash a password using Argon2.
--- Returns an encoded string suitable for storage.
--- @param pwd string The password to hash
--- @param options HashOptions? Optional configuration for the hash
--- @return string? The encoded hash string, or nil on error
--- @return string? Error message if hashing failed
local function password(pwd: string, options?: HashOptions): string | nil, string
  -- Build config from options
  -- Default m_cost to 19456 KiB (19 MiB) per OWASP minimum recommendation.
  local config: argon2.Config = {m_cost = 19456}
  if options then
    if options.m_cost then config.m_cost = options.m_cost end
    if options.t_cost then config.t_cost = options.t_cost end
    if options.parallelism then config.parallelism = options.parallelism end
    if options.hash_len then config.hash_len = options.hash_len end
    if options.variant then
      -- The generated argon2.Variant enum checks literals statically;
      -- runtime strings smuggled in through casts still get nil, err
      -- rather than the binding's raise (never throw from library code).
      if options.variant == "argon2id" or options.variant == "argon2i"
      or options.variant == "argon2d" then
        config.variant = options.variant
      else
        return nil, "invalid variant: " .. tostring(options.variant)
          .. " (expected argon2id, argon2i, or argon2d)"
      end
    end
  end

  -- salt = nil: the binding generates 16 random bytes with a CSPRNG.
  local encoded, err = argon2.hash_encoded(pwd, nil, config)
  if not encoded then
    return nil, err as string
  end
  return encoded
end

--- Verify a password against an Argon2 encoded hash.
--- Returns true on match, false (no error) on clean mismatch, or
--- false plus an error string when the hash is malformed or the binding
--- reports an error (e.g. "Decoding failed").
--- @param encoded string The encoded hash string (from password)
--- @param pwd string The password to verify
--- @return boolean True if the password matches, false otherwise
--- @return string? Error message if the hash is malformed or another error occurred
local function verify_password(encoded: string, pwd: string): boolean, string
  local ok, err = argon2.verify(encoded, pwd)
  if err then
    -- Malformed encoded string or another binding error.
    return false, err
  end
  return ok
end

local record HashModule
  type Algo = Algo
  type HashOptions = HashOptions

  digest: function(algo: Algo, data: string): string | nil, string
  hmac: function(algo: Algo, key: string, data: string): string | nil, string
  sha256: function(data: string): string
  sha256_hex: function(data: string): string
  hmac_sha256: function(key: string, data: string): string
  constant_time_equal: function(a: string, b: string): boolean
  password: function(pwd: string, options?: HashOptions): string | nil, string
  verify_password: function(encoded: string, pwd: string): boolean, string
end

local M: HashModule = {
  digest = digest,
  hmac = hmac,
  sha256 = sha256,
  sha256_hex = sha256_hex,
  hmac_sha256 = hmac_sha256,
  constant_time_equal = constant_time_equal,
  password = password,
  verify_password = verify_password,
}

return M
