--- Random number generation.
--- Wraps cosmo.GetRandomBytes for cryptographically secure randomness, and
--- cosmo.Rand64 for fast non-cryptographic use cases.
---
--- Example usage:
---   local rand = require("cosmic.rand")
---   local key, err = rand.bytes(32)     -- cryptographically secure
---   local roll = rand.int(1, 6)         -- crypto-grade, unbiased
---   local n = rand.insecure64()             -- fast pseudo-random (not secure)
local cosmo = require("cosmo")

--- Generate cryptographically secure random bytes.
--- @param n integer The number of random bytes to generate (1..4194304)
--- @return string | nil Random bytes, or nil on failure
--- @return string? Error message on failure
local function bytes(n: integer): string | nil, string
  local data, err = cosmo.GetRandomBytes(n)
  if not data then
    return nil, err or "GetRandomBytes failed"
  end
  return data
end

--- Generate a fast 64-bit pseudo-random integer (non-cryptographic).
--- Note: result is a signed 64-bit Lua integer; may appear negative if high bit is set.
--- @return integer Random 64-bit integer
local function insecure64(): integer
  return cosmo.Rand64()
end

--- Generate a cryptographically secure uniform integer in [min, max]
--- (both inclusive). Rejection-sampled over bytes(), so the result is
--- unbiased — unlike the common `min + rand % range` shortcut.
--- The range size (max - min + 1) must not exceed 2^53.
--- @param min integer Lower bound (inclusive)
--- @param max integer Upper bound (inclusive)
--- @return integer | nil The random integer, or nil on failure
--- @return string? Error message on failure
local function int(min: integer, max: integer): integer | nil, string
  if math.type(min) ~= "integer" or math.type(max) ~= "integer" then
    return nil, "rand.int: min and max must be integers"
  end
  if min > max then
    return nil, "rand.int: min must be <= max"
  end
  local range = max - min + 1
  -- range <= 0 means max - min overflowed the signed 64-bit space.
  if range <= 0 or range > (1 << 53) then
    return nil, "rand.int: range too large (max 2^53)"
  end
  -- Smallest byte count whose value space covers the range.
  local nbytes = 1
  local space = 256
  while space < range do
    nbytes = nbytes + 1
    space = space * 256
  end
  -- Rejection sampling: draw values until one lands under the largest
  -- multiple of range, so every residue is equally likely. Each draw
  -- accepts with probability > 1/2, so the expected iteration count is < 2.
  local limit = space - (space % range)
  while true do
    local data, err = bytes(nbytes)
    if not data then
      return nil, err
    end
    local v = 0
    for i = 1, nbytes do
      v = v * 256 + string.byte(data, i)
    end
    if v < limit then
      return min + v % range
    end
  end
end

--- Generate a cryptographically secure uniform float in [0, 1).
--- Uses 53 random bits, so the result has full double precision.
--- @return number | nil The random float, or nil on failure
--- @return string? Error message on failure
local function float(): number | nil, string
  local v, err = int(0, (1 << 53) - 1)
  if not v then
    return nil, err
  end
  return v / (1 << 53)
end

--- Pick one element of a list uniformly at random (crypto-grade).
--- @param list {any} The list to pick from
--- @return any The chosen element, or nil on failure or empty list
--- @return string? Error message on failure or empty list
local function choice(list: {any}): any, string
  if #list == 0 then
    return nil, "rand.choice: empty list"
  end
  local i, err = int(1, #list)
  if not i then
    return nil, err
  end
  return list[i as integer] -- cast: nil not narrowed after guard
end

--- Shuffle a list in place with an unbiased Fisher-Yates pass
--- (crypto-grade). Returns the same list for call chaining.
--- @param list {any} The list to shuffle (mutated in place)
--- @return {any} | nil The shuffled list, or nil on failure
--- @return string? Error message on failure
local function shuffle(list: {any}): {any} | nil, string
  for i = #list, 2, -1 do
    local j, err = int(1, i)
    if not j then
      return nil, err
    end
    local jj = j as integer -- cast: nil not narrowed after guard
    list[i], list[jj] = list[jj], list[i]
  end
  return list
end

local TOKEN_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

--- Generate a random alphanumeric token (crypto-grade, unbiased).
--- Tokens are URL- and filename-safe. Each character carries ~5.95 bits
--- of entropy, so the default 32 characters give ~190 bits.
--- @param len integer? Token length in characters (default 32)
--- @return string | nil The token, or nil on failure
--- @return string? Error message on failure
local function token(len?: integer): string | nil, string
  len = len or 32
  if len < 1 then
    return nil, "rand.token: len must be positive"
  end
  local chars: {string} = {}
  for i = 1, len do
    local j, err = int(1, #TOKEN_ALPHABET)
    if not j then
      return nil, err
    end
    local jj = j
    chars[i] = TOKEN_ALPHABET:sub(jj, jj)
  end
  return table.concat(chars)
end

local record RandModule
  bytes: function(n: integer): string | nil, string
  int: function(min: integer, max: integer): integer | nil, string
  float: function(): number | nil, string
  choice: function(list: {any}): any, string
  shuffle: function(list: {any}): {any} | nil, string
  token: function(len?: integer): string | nil, string
  insecure64: function(): integer
end

local M: RandModule = {
  bytes = bytes,
  int = int,
  float = float,
  choice = choice,
  shuffle = shuffle,
  token = token,
  insecure64 = insecure64,
}

return M
